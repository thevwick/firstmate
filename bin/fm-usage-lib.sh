# shellcheck shell=bash
# fm-usage-lib.sh - shared help-text printer for bin/ entrypoints.
#
# ONE owner for "print a script's leading comment header as its --help output",
# so a script's help can never silently truncate as its header grows. Nothing
# here is specific to any one feature; any bin/ entrypoint may source it.
#
# Sourced, not executed. No side effects on source. set -u / set -e safe.
# Depends on nothing else in bin/.

# fm_usage_header <script-path>: print <script-path>'s leading comment header as
# help text, stopping at the first real code line. The shebang is skipped, and a
# blank line inside the header is a paragraph break, not the end of the header.
# The bin/ scripts that still print a hardcoded line range are deliberately
# untouched.
fm_usage_header() {
  awk '
    NR == 1 { next }
    /^[[:space:]]*$/ { print ""; next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$1"
}
