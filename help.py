import os

def concatenate_files(directories, output_path, encoding="utf-8"):
    """
    Recursively walks through a list of directories, reads all files, and writes
    their contents to an output file. Each file is separated by a header line
    showing its filename.

    Args:
        directories (list[str]): List of directory paths to search.
        output_path (str): Path to the output file.
        encoding (str): Encoding to use when reading/writing files (default utf-8).
    """
    with open(output_path, "w", encoding=encoding) as outfile:
        for directory in directories:
            for root, _, files in os.walk(directory):
                for filename in files:
                    filepath = os.path.join(root, filename)
                    try:
                        with open(filepath, "r", encoding=encoding) as infile:
                            content = infile.read()
                    except (UnicodeDecodeError, PermissionError, IsADirectoryError):
                        # Skip binary or unreadable files
                        continue

                    # Write formatted section
                    outfile.write("\n\n// " + filename + "\n\n")
                    outfile.write(content)
                    outfile.write("\n")  # Ensure trailing newline for readability

    print(f"✅ Combined output written to: {output_path}")

dirs = [
    "src/engine",
    "src/shaders",
]

concatenate_files(dirs, "stone.zig")
