#!/usr/bin/env python3
import os
import csv
import shutil
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

# ================= 配置区域 =================
MOUNT_MAP = {
    "/mnt/Old-1": "V:",
    "/mnt/Old-2": "W:",
    "/mnt/New-1": "X:",
    "/mnt/New-2": "Y:"
}

IGNORE_DIRS = {
    '$recycle.bin', 'system volume information', '__pycache__', 
    '.git', '.idea', '.vscode', 'node_modules', 'recovery', 
    '#recycle', '@eadir', 'found.000', 'found.001',
    '.stfolder', '.stversions', '.recycle'
}

LEVEL_LIMIT = 4
MAX_WORKERS = 4  # One worker per physical source disk.
IO_BUFFER_SIZE = 1024 * 1024

# 输出路径
EFU_PATH = "/mnt/SSD-Cache/Tree/nas_files.efu"
TREE_OUTPUT_DIR = "/mnt/SSD-Cache/Syncthing/文本信息/Tree"
TREE_OUTPUT_FILE = os.path.join(TREE_OUTPUT_DIR, "TreeScan_Latest.txt")
EFU_HEADER = b"Filename,Size,Date Modified,Attributes\r\n"

# ================= Trie 树结构（用于内存生成 Tree） =================
class TrieNode:
    def __init__(self):
        self.dirs = {}  # name -> TrieNode
        self.files = set()

def insert_to_trie(trie, relative_parts, name, is_dir):
    if len(relative_parts) >= LEVEL_LIMIT:
        return  # 超过 4 层深度，直接忽略，不占内存
        
    node = trie
    for comp in relative_parts:
        if comp not in node.dirs:
            node.dirs[comp] = TrieNode()
        node = node.dirs[comp]
        
    if is_dir:
        if name not in node.dirs:
            node.dirs[name] = TrieNode()
    else:
        node.files.add(name)

def generate_tree_output(node, file_handle, prefix=''):
    sorted_dirs = sorted(node.dirs.keys(), key=lambda s: s.lower())
    sorted_files = sorted(node.files, key=lambda s: s.lower())
    
    entries = [(d, True) for d in sorted_dirs] + [(f, False) for f in sorted_files]
    count = len(entries)
    
    for i, (name, is_dir) in enumerate(entries):
        is_last = (i == count - 1)
        pointer = '└── ' if is_last else '├── '
        display_name = (name + '/') if is_dir else name
        file_handle.write(f"{prefix}{pointer}{display_name}\n")
        
        if is_dir:
            extension = '    ' if is_last else '│   '
            generate_tree_output(node.dirs[name], file_handle, prefix + extension)

def get_win_filetime(unix_time):
    return int((unix_time + 11644473600) * 10000000)

def to_win_path(parent_win_path, name):
    return parent_win_path + "\\" + name


def scan_mount(linux_path, win_drive, fragment_path):
    """Scan one mount point and write its EFU rows to a private fragment."""
    trie = TrieNode()
    total_count = 0
    error_count = 0
    start_time = time.perf_counter()

    # Carry relative components and the Windows parent path through the walk.
    # This avoids rebuilding them with relpath()/split() for every entry.
    pending = [(linux_path, (), win_drive)]

    with open(
        fragment_path,
        "w",
        encoding="utf-8",
        newline="",
        buffering=IO_BUFFER_SIZE,
    ) as f_efu:
        writer = csv.writer(f_efu, doublequote=True)

        while pending:
            root, relative_parts, parent_win_path = pending.pop()
            directories = []
            files = []

            try:
                with os.scandir(root) as entries:
                    for entry in entries:
                        try:
                            is_real_dir = entry.is_dir(follow_symlinks=False)
                            is_dir = is_real_dir

                            # Match os.walk's behavior: include symlinked
                            # directories, but do not recurse into them.
                            if not is_dir and entry.is_symlink():
                                is_dir = entry.is_dir(follow_symlinks=True)

                            if is_dir:
                                if entry.name.lower() not in IGNORE_DIRS:
                                    directories.append((entry, is_real_dir))
                            else:
                                files.append(entry)
                        except OSError:
                            error_count += 1

                    subdirectories = []

                    # Keep the existing EFU ordering: directories first,
                    # followed by files in each visited directory.
                    for entry, is_real_dir in directories:
                        win_path = to_win_path(parent_win_path, entry.name)

                        if is_real_dir:
                            child_parts = relative_parts + (entry.name,)
                            subdirectories.append(
                                (entry.path, child_parts, win_path)
                            )

                        try:
                            stat_result = entry.stat(follow_symlinks=True)
                            writer.writerow(
                                [
                                    win_path,
                                    0,
                                    get_win_filetime(stat_result.st_mtime),
                                    16,
                                ]
                            )
                            insert_to_trie(
                                trie, relative_parts, entry.name, is_dir=True
                            )
                            total_count += 1
                        except OSError:
                            error_count += 1

                    for entry in files:
                        try:
                            stat_result = entry.stat(follow_symlinks=True)
                            writer.writerow(
                                [
                                    to_win_path(parent_win_path, entry.name),
                                    stat_result.st_size,
                                    get_win_filetime(stat_result.st_mtime),
                                    32,
                                ]
                            )
                            insert_to_trie(
                                trie, relative_parts, entry.name, is_dir=False
                            )
                            total_count += 1
                            if total_count % 500000 == 0:
                                print(
                                    f"{linux_path}: 已扫描 {total_count} 个项目...",
                                    flush=True,
                                )
                        except OSError:
                            error_count += 1
            except OSError:
                # Keep walking behavior: an unreadable directory only drops
                # that subtree instead of aborting the whole mount scan.
                error_count += 1
                continue

            # A LIFO stack plus reversed insertion preserves directory order.
            for subdirectory in reversed(subdirectories):
                pending.append(subdirectory)

    return trie, total_count, error_count, time.perf_counter() - start_time


def make_temp_path(directory, prefix):
    fd, path = tempfile.mkstemp(prefix=prefix, dir=directory)
    os.close(fd)
    return path


def remove_file(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def merge_efu_fragments(fragment_paths):
    """Merge UTF-8 fragments and atomically publish the final EFU file."""
    output_dir = os.path.dirname(EFU_PATH)
    temporary_output = make_temp_path(output_dir, ".nas_files.")

    try:
        with open(
            temporary_output,
            "wb",
            buffering=IO_BUFFER_SIZE,
        ) as f_efu:
            f_efu.write(EFU_HEADER)
            for fragment_path in fragment_paths:
                with open(fragment_path, "rb", buffering=IO_BUFFER_SIZE) as fragment:
                    shutil.copyfileobj(fragment, f_efu, IO_BUFFER_SIZE)

        os.chmod(temporary_output, 0o644)
        os.replace(temporary_output, EFU_PATH)
    finally:
        remove_file(temporary_output)

# ================= 主运行逻辑 =================
def main():
    print("=== [一箭双雕] 引擎启动 ===")
    start_time = time.perf_counter()
    total_count = 0
    
    # 确保输出目录存在
    os.makedirs(os.path.dirname(EFU_PATH), exist_ok=True)
    os.makedirs(TREE_OUTPUT_DIR, exist_ok=True)
    
    # 初始化 Trie 树
    tries = {linux_path: TrieNode() for linux_path in MOUNT_MAP.keys()}

    # 1. Scan all physical disks in parallel, each into its own EFU fragment.
    scan_jobs = []
    fragment_paths = []
    scan_results = {}

    try:
        for linux_path, win_drive in MOUNT_MAP.items():
            if not os.path.exists(linux_path):
                print(f"警告: 目录 {linux_path} 不存在，跳过。")
                continue

            fragment_path = make_temp_path(
                os.path.dirname(EFU_PATH), ".nas_files.part."
            )
            fragment_paths.append(fragment_path)
            scan_jobs.append((linux_path, win_drive, fragment_path))

        if scan_jobs:
            print(
                "正在并行扫描: "
                + ", ".join(linux_path for linux_path, _, _ in scan_jobs)
            )
            worker_count = min(MAX_WORKERS, len(scan_jobs))
            with ThreadPoolExecutor(max_workers=worker_count) as executor:
                future_paths = {
                    executor.submit(
                        scan_mount, linux_path, win_drive, fragment_path
                    ): linux_path
                    for linux_path, win_drive, fragment_path in scan_jobs
                }

                for future in as_completed(future_paths):
                    linux_path = future_paths[future]
                    tries[linux_path], count, errors, elapsed = future.result()
                    scan_results[linux_path] = (count, errors, elapsed)

            for linux_path, _, _ in scan_jobs:
                count, errors, elapsed = scan_results[linux_path]
                total_count += count
                error_text = f", 失败 {errors} 项" if errors else ""
                print(
                    f"{linux_path}: {count} 个项目, "
                    f"耗时 {elapsed:.2f} 秒{error_text}"
                )

        merge_efu_fragments(
            [fragment_path for _, _, fragment_path in scan_jobs]
        )
    finally:
        for fragment_path in fragment_paths:
            remove_file(fragment_path)

    # 2. 内存生成完美格式的 Tree 文件（不带 Windows 盘符，纯 Linux 路径展示）
    print("正在从内存 Trie 中导出 Tree 报告...")
    with open(
        TREE_OUTPUT_FILE,
        "w",
        encoding="utf-8",
        buffering=IO_BUFFER_SIZE,
    ) as f_tree:
        f_tree.write("=" * 50 + "\n")
        f_tree.write(" 文件树扫描报告\n")
        f_tree.write(f" 扫描时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f_tree.write(f" 扫描位置: {', '.join(MOUNT_MAP.keys())}\n")
        f_tree.write(f" 深度限制: {LEVEL_LIMIT} 层\n")
        f_tree.write("=" * 50 + "\n\n")
        
        for i, linux_path in enumerate(sorted(MOUNT_MAP.keys())):
            if i > 0:
                f_tree.write("\n" + "=" * 50 + "\n\n")
            f_tree.write(f"磁盘/挂载点: {linux_path}\n\n")
            f_tree.write(f"{linux_path}\n")
            generate_tree_output(tries[linux_path], f_tree)

    # 3. 纠正所有权
    try:
        os.chown(EFU_PATH, 1000, 1000)
        os.chown(TREE_OUTPUT_FILE, 1000, 1000)
    except OSError:
        pass

    end_time = time.perf_counter()
    print(f"=== 运行成功 ===")
    print(f"EFU 保存至: {EFU_PATH}")
    print(f"Tree 保存至: {TREE_OUTPUT_FILE}")
    print(f"总处理项目: {total_count}")
    print(f"总共耗时: {end_time - start_time:.2f} 秒")

if __name__ == "__main__":
    main()
