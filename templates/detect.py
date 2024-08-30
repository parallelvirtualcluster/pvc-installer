#!/usr/bin/env python3

import subprocess
import sys
from json import loads as loads
from re import match as re_match
from re import search as re_search
from re import sub as re_sub
from shlex import split as shlex_split

#
# Run a local OS command via shell
#
def run_os_command(command_string, background=False, environment=None, timeout=None):
    if not isinstance(command_string, list):
        command = shlex_split(command_string)
    else:
        command = command_string

    if background:

        def runcmd():
            try:
                subprocess.run(
                    command,
                    env=environment,
                    timeout=timeout,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            except subprocess.TimeoutExpired:
                pass

        thread = Thread(target=runcmd, args=())
        thread.start()
        return 0, None, None
    else:
        try:
            command_output = subprocess.run(
                command,
                env=environment,
                timeout=timeout,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            retcode = command_output.returncode
        except subprocess.TimeoutExpired:
            retcode = 128
        except Exception:
            retcode = 255

        try:
            stdout = command_output.stdout.decode("ascii")
        except Exception:
            stdout = ""
        try:
            stderr = command_output.stderr.decode("ascii")
        except Exception:
            stderr = ""
        return retcode, stdout, stderr

def get_detect_device_lsscsi(detect_string):
    """
    Parses a "detect:" string into a normalized block device path using lsscsi.

    A detect string is formatted "detect:<NAME>:<SIZE>:<ID>", where
    NAME is some unique identifier in lsscsi, SIZE is a human-readable
    size value to within +/- 3% of the real size of the device, and
    ID is the Nth (0-indexed) matching entry of that NAME and SIZE.
    """
    _, name, size, idd = detect_string.split(":")
    if _ != "detect":
        return None

    retcode, stdout, stderr = run_os_command("lsscsi -s")
    if retcode:
        print(f"Failed to run lsscsi: {stderr}")
        return None

    # Get valid lines
    lsscsi_lines_raw = stdout.split("\n")
    lsscsi_lines = list()
    for line in lsscsi_lines_raw:
        if not line:
            continue
        split_line = line.split()
        if split_line[1] != "disk":
            continue
        lsscsi_lines.append(line)

    # Handle size determination (+/- 3%)
    lsscsi_sizes = set()
    for line in lsscsi_lines:
        lsscsi_sizes.add(split_line[-1])
    for l_size in lsscsi_sizes:
        b_size = float(re_sub(r"\D.", "", size))
        t_size = float(re_sub(r"\D.", "", l_size))

        plusthreepct = t_size * 1.03
        minusthreepct = t_size * 0.97

        if b_size > minusthreepct and b_size < plusthreepct:
            size = l_size
            break

    blockdev = None
    matches = list()
    for idx, line in enumerate(lsscsi_lines):
        # Skip non-disk entries
        if line.split()[1] != "disk":
            continue
        # Skip if name is not contained in the line (case-insensitive)
        if name.lower() not in line.lower():
            continue
        # Skip if the size does not match
        if size != line.split()[-1]:
            continue
        # Get our blockdev and append to the list
        matches.append(line.split()[-2])

    blockdev = None
    # Find the blockdev at index {idd}
    for idx, _blockdev in enumerate(matches):
        if int(idx) == int(idd):
            blockdev = _blockdev
            break

    return blockdev

def get_detect_device_nvme(detect_string):
    """
    Parses a "detect:" string into a normalized block device path using nvme.

    A detect string is formatted "detect:<NAME>:<SIZE>:<ID>", where
    NAME is some unique identifier in lsscsi, SIZE is a human-readable
    size value to within +/- 3% of the real size of the device, and
    ID is the Nth (0-indexed) matching entry of that NAME and SIZE.
    """

    unit_map = {
        'kB': 1000,
        'MB': 1000*1000,
        'GB': 1000*1000*1000,
        'TB': 1000*1000*1000*1000,
        'PB': 1000*1000*1000*1000*1000,
    }

    _, name, _size, idd = detect_string.split(":")
    if _ != "detect":
        return None

    size_re = re_search(r'(\d+)([kKMGTP]B)', _size)
    size_val = float(size_re.group(1))
    size_unit = size_re.group(2)
    size_bytes = int(size_val * unit_map[size_unit])

    retcode, stdout, stderr = run_os_command("nvme list --output-format json")
    if retcode:
        print(f"Failed to run nvme: {stderr}")
        return None

    # Parse the output with json
    nvme_data = loads(stdout).get('Devices', list())

    # Handle size determination (+/- 3%)
    size = None
    nvme_sizes = set()
    for entry in nvme_data:
        nvme_sizes.add(entry['PhysicalSize'])
    for l_size in nvme_sizes:
        plusthreepct = size_bytes * 1.03
        minusthreepct = size_bytes * 0.97

        if l_size > minusthreepct and l_size < plusthreepct:
            size = l_size
            break
    if size is None:
        return None

    blockdev = None
    matches = list()
    for entry in nvme_data:
        # Skip if name is not contained in the line (case-insensitive)
        if name.lower() not in entry['ModelNumber'].lower():
            continue
        # Skip if the size does not match
        if size != entry['PhysicalSize']:
            continue
        # Get our blockdev and append to the list
        matches.append(entry['DevicePath'])

    blockdev = None
    # Find the blockdev at index {idd}
    for idx, _blockdev in enumerate(matches):
        if int(idx) == int(idd):
            blockdev = _blockdev
            break

    return blockdev


def get_detect_device(detect_string):
    """
    Parses a "detect:" string into a normalized block device path.

    First tries to parse using "lsscsi" (get_detect_device_lsscsi). If this returns an invalid
    block device name, then try to parse using "nvme" (get_detect_device_nvme). This works around
    issues with more recent devices (e.g. the Dell R6615 series) not properly reporting block
    device paths for NVMe devices with "lsscsi".
    """

    device = get_detect_device_lsscsi(detect_string)
    if device is None or not re_match(r'^/dev', device):
        device = get_detect_device_nvme(detect_string)

    if device is not None and re_match(r'^/dev', device):
        return device
    else:
        return None


try:
    detect_string = sys.argv[1]
except IndexError:
    print("Please specify a detect: string")
    exit(1)

blockdev = get_detect_device(detect_string)
if blockdev is not None:
    print(blockdev)
    exit(0)
else:
    exit(1)

