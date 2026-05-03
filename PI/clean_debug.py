import re
import os

TARGET_FILE = "rpi_realtime_pipeline.py"

with open(TARGET_FILE, "r", encoding="utf-8") as f:
    code = f.read()

# ❌ remove debug region
code = re.sub(
    r"# region agent log.*?# endregion",
    "",
    code,
    flags=re.DOTALL,
)

# ❌ remove debug functions
code = re.sub(r"def _early_dbg_log\(.*?\n\)", "", code, flags=re.DOTALL)

# ❌ remove debug variables
code = re.sub(r"_DEBUG_.*\n", "", code)

# ❌ remove debug calls
code = re.sub(r"_early_dbg_log\(.*?\)\n", "", code, flags=re.DOTALL)
code = re.sub(r"_dbg_log\(.*?\)\n", "", code, flags=re.DOTALL)

with open(TARGET_FILE, "w", encoding="utf-8") as f:
    f.write(code)

print("✅ Cleaned debug code")