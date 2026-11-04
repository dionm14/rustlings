#!/bin/bash
# grep64.sh -- find 32->64-bit port bugs in C/C++ source without running anything.
#
# USAGE
#   ./grep64.sh <source_dir> [build_log] > grep64-report.txt
#
#   build_log (optional): the full output of one build with  -Wall -Wextra
#   (no -Werror), e.g.   make 2>&1 | tee build.log
#
# OPTIONS (environment variables)
#   GREP64_EXCLUDE="third_party:external:build"   directory names to skip
#   GREP64_TSV=/path/hits.tsv     also write every hit as tab-separated rows
#                                 (tier, check, title, file, line, code) to
#                                 split the work in a spreadsheet
#   GREP64_VARARGS="MyLog|MyMsg"  extra variadic functions to check for a
#                                 bare 0 terminator (see check S4 / R10)
#   GREP64_UNSIGNED32="MyU32"     extra project-specific 32-bit type names,
#   GREP64_SIGNED32="MyS32"       on top of the PROJECT_* lists below
#
# The report starts with a summary. Work it top-down:
#   FIX     each hit is almost always a real bug
#   REVIEW  look at each hit; many will be fine
#
# Needs: bash, GNU grep, find, awk (gawk or mawk), sort, sed.

set -u

SRC=${1:-}
LOG=${2:-}
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "usage: $0 <source_dir> [build_log] > report.txt" >&2
    exit 2
fi
if [ -n "$LOG" ] && [ ! -r "$LOG" ]; then
    echo "cannot read build log: $LOG" >&2
    exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/grep64.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
TSV=${GREP64_TSV:-}
[ -n "$TSV" ] && : > "$TSV"

# ---------------------------------------------------------------- file lists
prune=( -name .git -o -name .svn -o -name CVS )
IFS=: read -r -a extra_excl <<< "${GREP64_EXCLUDE:-}"
for d in "${extra_excl[@]:-}"; do
    [ -n "$d" ] && prune+=( -o -name "$d" )
done

find "$SRC" \( -type d \( "${prune[@]}" \) \) -prune -o -type f \( \
    -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.c++' \
    -o -name '*.C' -o -name '*.pc' -o -name '*.inl' -o -name '*.ipp' -o -name '*.tcc' \
    -o -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' -o -name '*.h++' \
    -o -name '*.H' \) -print0 > "$T/all"
find "$SRC" \( -type d \( "${prune[@]}" \) \) -prune -o -type f \( \
    -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' -o -name '*.h++' \
    -o -name '*.H' \) -print0 > "$T/hdr"
find "$SRC" \( -type d \( "${prune[@]}" \) \) -prune -o -type f \( \
    -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.c++' \
    -o -name '*.C' -o -name '*.pc' \) -print0 > "$T/src"

nfiles=$(tr -cd '\0' < "$T/all" | wc -c)

# --------------------------------------------------------------- helpers
# Lines whose code starts with a comment are dropped; long lines are trimmed.
clean() { grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*([[:space:]]|/|$))' | cut -c1-260; }

# emit TIER ID TITLE WHY FIX  (hits on stdin, "file:line:code")
emit() {
    local tier=$1 id=$2 title=$3 why=$4 fix=$5 n
    local seq
    seq=$(( $(cat "$T/seq" 2>/dev/null || echo 0) + 1 ))
    echo "$seq" > "$T/seq"
    local f="$T/sec.$(printf %03d "$seq")"
    sort -t: -k1,1 -k2,2n -u > "$f.hits"
    n=$(wc -l < "$f.hits" | tr -d ' ')
    printf '  %-4s %6s  %s\n' "$id" "$n" "$title" >> "$T/sum.$tier"
    {
        echo
        echo "=============================================================================="
        printf '[%s] %s  %s   (%s hits)\n' "$tier" "$id" "$title" "$n"
        echo "------------------------------------------------------------------------------"
        echo "$why" | fold -s -w 78 | sed 's/^/  /'
        echo "$fix" | fold -s -w 70 | sed '1s/^/  FIX: /; 2,$s/^/       /'
        echo "------------------------------------------------------------------------------"
        cat "$f.hits"
    } > "$f.$tier"
    if [ -n "$TSV" ] && [ "$n" -gt 0 ]; then
        awk -v tier="$tier" -v id="$id" -v title="$title" -F: 'BEGIN{OFS="\t"}
            { file=$1; line=$2; code=$0; sub(/^[^:]*:[^:]*:/, "", code);
              gsub(/\t/, " ", code); print tier, id, title, file, line, code }' \
            "$f.hits" >> "$TSV"
    fi
}

src()  { xargs -0 -r grep -IHnE -- "$1" < "$T/all" 2>/dev/null | clean; }
srcs() { xargs -0 -r grep -IHnE -- "$1" < "$T/src" 2>/dev/null | clean; }
hdrs() { xargs -0 -r grep -IHnE -- "$1" < "$T/hdr" 2>/dev/null | clean; }

# ---------------------------------------------------------------------------
# This project's own 32-bit integer type names, separated by |
# Used by checks S1, S3, R6 and R8; the unsigned ones also by S2.
PROJECT_UNSIGNED32='Uint32_t'
PROJECT_SIGNED32='Int32_t'
# ---------------------------------------------------------------------------
[ -n "${GREP64_UNSIGNED32:-}" ] && PROJECT_UNSIGNED32="$PROJECT_UNSIGNED32|$GREP64_UNSIGNED32"
[ -n "${GREP64_SIGNED32:-}" ] && PROJECT_SIGNED32="$PROJECT_SIGNED32|$GREP64_SIGNED32"
# tidy a |-separated list; an empty list must never become an empty regex branch
tidy() { local v; v=$(printf '%s' "$1" | tr -d ' \t' | sed 's/||*/|/g; s/^|//; s/|$//'); echo "${v:-__grep64_none__}"; }
MYU32=$(tidy "$PROJECT_UNSIGNED32")
MY32=$(tidy "$PROJECT_UNSIGNED32|$PROJECT_SIGNED32")

# Type-name groups
T32='int|unsigned|unsigned int|signed int|DWORD|UINT|uint|u_int|uint32_t|int32_t|u_int32_t|UINT32|INT32|uint32|int32|u32|s32'"|$MY32"
PTRSZ='long|unsigned long|long int|unsigned long int|size_t|ssize_t|uintptr_t|intptr_t|ptrdiff_t|DWORD_PTR|ULONG_PTR|UINT_PTR|INT_PTR|LONG_PTR|caddr_t'
VARARGS='execl|execlp|execle|XtVa[A-Za-z]*|XmVa[A-Za-z]*|g_object_new|g_object_set|g_object_get|g_strconcat|g_build_filename'
[ -n "${GREP64_VARARGS:-}" ] && VARARGS="$VARARGS|$GREP64_VARARGS"

echo "scanning $nfiles files under $SRC ..." >&2

# ============================================================ FIX: source
src "\(\s*($T32)\s*\)\s*\(\s*($PTRSZ)\s*\)|static_cast<\s*($T32)\s*>\s*\(\s*reinterpret_cast<" |
emit FIX S1 "Pointer squeezed into 32 bits with a double cast" \
"A cast like (unsigned)(uintptr_t)ptr exists only to silence the compiler's 'loses precision' error. The top 32 bits of the pointer are thrown away; using the value as a pointer later crashes or corrupts memory. No compiler flag warns about this. Safe in one case: the value was a small int stored in a void* user-data field (clientData, XtPointer, thread arg) and is being taken back out." \
"Store it in uintptr_t / intptr_t (or keep it a pointer). If it goes into a 32-bit field of a struct or API, that field has to grow or the design has to change (e.g. a lookup table of handles)."

src "\b(unsigned(\s+int)?|DWORD|UINT|uint|u_int|ULONG|uint32_t|UINT32|uint32|u32|$MYU32)\s+\w+\s*=\s*[^;]*\.(r?find|find_(first|last)_(not_)?of)\s*\(" |
emit FIX S2 "string::find() result stored in a 32-bit unsigned" \
"'Not found' is std::string::npos. On 64-bit it no longer fits in 32 bits, so 'pos == npos' is never true: not-found is treated as found at position 4294967295 and the code reads far past the string." \
"Declare the variable as size_t (or std::string::size_type). Also check variables of these types that are assigned a find() result on a later line."

src "\*\s*\*.*\b(malloc|calloc|realloc|alloca)\s*\(.*(sizeof\s*\(\s*(int|unsigned|unsigned int|DWORD|UINT|int32_t|uint32_t|$MY32)\s*\)|\*\s*4\b|\b4\s*\*|,\s*4\s*\))" |
emit FIX S3 "Array of pointers allocated with 4 bytes per element" \
"A pointer is now 8 bytes. An array of pointers sized with sizeof(int) or a literal 4 is half as big as it needs to be, so filling it overruns the heap block and corrupts whatever is next to it." \
"Use sizeof(*ptr) or sizeof(T*) for the element size, e.g. (char**)malloc(n * sizeof(char*))."

xargs -0 -r awk -v re="$VARARGS" '
    FNR == 1 { inside = 0 }
    {
        code = $0; sub(/\/\/.*$/, "", code)
        if (!inside) {
            if (code !~ "(^|[^A-Za-z0-9_])(" re ")[ \t]*\\(") next
            if (code ~ /\.\.\./) next                       # a prototype
            inside = 1; start = FNR; first = $0; buf = code; n = 0
        } else { buf = buf " " code; n++ }
        if (buf ~ /;/) {
            if (buf ~ /,[ \t]*0[ \t]*\)[ \t]*;/) print FILENAME ":" start ":" first
            inside = 0
        } else if (n > 80) inside = 0
    }' < "$T/all" 2>/dev/null | clean |
emit FIX S4 "Variadic call ended with a bare 0 instead of NULL" \
"Functions like execl() and XtVaSetValues() read the terminator as a 64-bit pointer. A bare 0 is passed as a 32-bit int, so the upper half is garbage, the end of the list is missed, and the function reads past its arguments. (Calls spanning several lines are reported at their first line.)" \
"End the list with NULL, nullptr or (char*)0. Add your own variadic functions with GREP64_VARARGS (see R10)."

src "^\s*typedef\s+(unsigned\s+|signed\s+)?long(\s+int)?\s+[A-Za-z_]*(32|DWORD|Dword|ULONG|Ulong|LONG)[A-Za-z0-9_]*\s*;|^\s*#\s*define\s+[A-Za-z_]*(32|DWORD|Dword|ULONG|Ulong|LONG)[A-Za-z0-9_]*\s+(unsigned\s+|signed\s+)?long(\s+int)?\s*(//.*|/\*.*)?$" |
emit FIX S5 "Type named like a 32-bit type but defined as long" \
"long is 64 bits on 64-bit Linux. A typedef such as 'typedef unsigned long DWORD;' silently grew every DWORD in the program to 8 bytes: every struct that uses it changed layout, including anything written to files, sockets, shared memory or hardware." \
"Define it from a fixed-width type: typedef uint32_t DWORD; (then rebuild and re-check the warnings, since some code may rely on the larger size)."

# ============================================================ REVIEW: source
xargs -0 -r awk '
    function strip(s) { sub(/\/\/.*$/, "", s); gsub(/\/\*([^*]|\*+[^*\/])*\*+\//, "", s); return s }
    function count(s, c,   t) { t = s; return gsub(c, "", t) }
    function risky(s) {
        if (s !~ /;/) return 0
        if (s ~ /^[ \t]*(\/\*|\*|})/) return 0
        if (s ~ /\(/ && s !~ /\([ \t]*\*/) return 0          # functions, not fn-pointer fields
        if (s ~ /(^|[^A-Za-z0-9_])long([^A-Za-z0-9_]|$)/ && s !~ /long[ \t]+(long|double)/) return 1
        if (s ~ /(^|[^A-Za-z0-9_])(size_t|ssize_t|time_t|ptrdiff_t|intptr_t|uintptr_t|off_t|clock_t|suseconds_t|caddr_t|DWORD_PTR|ULONG_PTR|LONG_PTR|UINT_PTR|INT_PTR|XtPointer)([^A-Za-z0-9_]|$)/) return 1
        if (s ~ /\*/) return 1
        return 0
    }
    function packval(s,   n) {       # 1 if the pragma sets packing to 1, 2 or 4
        if (match(s, /[0-9]+/)) { n = substr(s, RSTART, RLENGTH) + 0; return (n <= 4) }
        return -1
    }
    FNR == 1 { cur = 0; sp = 0; depth = 0; instruct = 0; pend = 0; nb = 0 }
    {
        code = strip($0)
        if (code ~ /^[ \t]*#[ \t]*pragma[ \t]+pack/) {
            v = packval(code)
            if (code ~ /pack[ \t]*\([ \t]*\)/) cur = 0
            else if (code ~ /pop/) { if (sp > 0) cur = stk[sp--]; else cur = 0 }
            else if (code ~ /push/) { stk[++sp] = cur; if (v >= 0) cur = v }
            else if (v >= 0) cur = v
            next
        }
        t = code
        gsub(/template[ \t]*<[^>]*>/, "", t)
        gsub(/__attribute__[ \t]*\(\([^)]*\)\)/, "", t)
        gsub(/(alignas|__declspec|__aligned)[ \t]*\([^)]*\)/, "", t)
        opens = count(code, "{"); closes = count(code, "}")
        kw = (t ~ /(^|[^A-Za-z0-9_])(struct|union|class)([^A-Za-z0-9_]|$)/ && t !~ /\(/)
        if (!instruct && opens > 0 && (kw || (pend && t ~ /^[ \t]*\{/))) {
            instruct = 1; sdepth = depth; openline = code; nb = 0; pend = 0
        } else if (!instruct && kw && code !~ /;/) pend = 1
        else if (code ~ /[;{}]/) pend = 0
        depth += opens - closes
        if (instruct) {
            if (risky(code)) {
                if (cur > 0) print FILENAME ":" FNR ":" $0
                else buf[++nb] = FILENAME ":" FNR ":" $0
            }
            if (depth <= sdepth) {
                if (cur == 0 && (code ~ /packed/ || openline ~ /packed/))
                    for (i = 1; i <= nb; i++) print buf[i]
                instruct = 0; nb = 0
            }
        }
    }' < "$T/all" 2>/dev/null | clean |
emit REVIEW R1 "Packed struct with a field that changed size" \
"Packed structs (#pragma pack, __attribute__((packed))) are almost always a fixed byte format: a file, a network message, shared memory, or a hardware/driver layout. Fields of type long, size_t, time_t or any pointer were 4 bytes and are now 8, so the layout no longer matches." \
"A real bug if anything other than this same 64-bit build reads or writes the data: files written by the old build, 32-bit peers, other nodes, hardware, other languages. Use fixed-width types (int32_t, uint32_t); pointers should not be in such a struct at all."

src "(\(|reinterpret_cast<|static_cast<)\s*(const\s+)?(volatile\s+)?(unsigned\s+long|signed\s+long|long|u_long|ulong|size_t|ssize_t|time_t|off_t|ptrdiff_t)(\s+int)?\s*(const\s*)?\*\s*(\)\s*[A-Za-z_&(*]|>)" |
grep -vE '\*\s*(\)|>\s*\()\s*[A-Za-z_:.>-]*(alloc|Alloc|ALLOC|new|New)[A-Za-z_]*\s*(\(|$|//|/\*)' |
emit REVIEW R2 "Memory read or written through a long* / size_t* / time_t* cast" \
"These types grew from 4 to 8 bytes. Code like *(long*)buf, written when long was 4 bytes, now reads 8 bytes (two fields mashed together) or writes 8 bytes (overwriting the neighbouring field)." \
"If the data is a 32-bit field, use (int32_t*) / (uint32_t*), or better, memcpy into a uint32_t. Fine if the memory really holds a long."

src "\b0[xX][fF]{8}([uU]?[lL]{0,2}|[lL]{1,2}[uU])\b|\b4294967295|&\s*~?\s*0[xX][fF]{7}[0-9a-fA-F]\b" |
emit REVIEW R3 "32-bit all-ones constant (0xFFFFFFFF, 4294967295)" \
"Often used as 'invalid' or 'not found', or as a mask. If the other side is now 64-bit (size_t, long, a pointer, npos, (size_t)-1), the comparison never matches; masking a pointer or size with 0xFFFFFFF0 wipes its top 32 bits." \
"For sentinels use the type's own value: (size_t)-1, std::string::npos, UINT32_MAX for a real uint32_t field. For alignment masks use ~(uintptr_t)15. Fine for genuine 32-bit protocol fields and CRCs."

src "\b(LONG_MAX|LONG_MIN|ULONG_MAX)\b" |
emit REVIEW R4 "LONG_MAX / LONG_MIN / ULONG_MAX" \
"Their values changed from about 2 billion to about 9.2 quintillion. Used as 'infinite' and passed to an int parameter, a 32-bit field, or a wire format, they now truncate to -1 or 0." \
"Use INT_MAX / UINT32_MAX when the destination is 32 bits."

src "sizeof\s*\(\s*(long|unsigned long|long int|void\s*\*|char\s*\*|[A-Za-z_]\w*\s*\*)\s*\)\s*(==|!=|<=|>=|<|>)\s*4\b|\b4\s*(==|!=)\s*sizeof\s*\(\s*(long|void\s*\*|[A-Za-z_]\w*\s*\*)\s*\)|^\s*#\s*(if|ifdef|ifndef|elif)\b.*\b(__i386__|__i386|i386|_M_IX86|__x86_64__|__x86_64|__amd64__|__amd64|_M_X64|_M_AMD64|__LP64__|_LP64|_ILP32|_WIN64|__WORDSIZE|BITS_PER_LONG|__SIZEOF_POINTER__|__SIZEOF_LONG__|SIZEOF_LONG|SIZEOF_VOID_P|SIZEOF_SIZE_T)\b" |
emit REVIEW R5 "Code that branches on the word size" \
"Checks like sizeof(long) == 4 and #ifdef __x86_64__ / _LP64 branches. In a codebase that only ever shipped 32-bit, the 64-bit side of these branches has never run." \
"Read the 64-bit branch as new, untested code. Remove branches that are no longer needed."

src "\(\s*(const\s+)?(unsigned\s+char|signed\s+char|char|BYTE|uint8_t|u_char|UCHAR|u8)\s*\*\s*\)\s*\(?\s*&?\s*[A-Za-z_]\w*(\s*(->|\.)\s*\w+)*\s*\)?\s*\+\s*([2-9]|[1-9][0-9]+)\b|\(\s*\(\s*(const\s+)?(int|unsigned|unsigned int|long|unsigned long|DWORD|short|unsigned short|uint32_t|int32_t|UINT|$MY32)\s*\*\s*\)\s*&?\s*[A-Za-z_]\w*\s*\)\s*\[\s*[0-9]+\s*\]" |
emit REVIEW R6 "Hard-coded byte offset into an object" \
"(char*)p + 8 or ((int*)p)[3] picks a field by a number of bytes worked out for the 32-bit layout. Any pointer or long earlier in the struct moved everything after it." \
"Use the field name, or offsetof(Type, field). Fine when parsing a byte buffer with a fixed external format."

src "\[[^]\[]*(/\s*32|>>\s*5)\s*\]" |
emit REVIEW R7 "Bit array indexed with /32 or >>5" \
"Bitmaps stored as arrays of unsigned long with a hard-coded 32 bits per word now use only half of each 64-bit word and index the wrong bits when shared with other code (e.g. FD_SET-style masks, select(), driver bitmaps)." \
"Fine if the array element type is a 32-bit type (uint32_t, unsigned int). If it is long, use sizeof(word) * CHAR_BIT instead of 32."

xargs -0 -r grep -IHnE -- "\b(fwrite|fread|write|read|pwrite|pread|send|recv|sendto|recvfrom|msgsnd|msgrcv)\s*\(.*(&\s*\(?\s*[A-Za-z_][^,]*,.*sizeof|sizeof\s*\(\s*struct\s|sizeof\s*\(?\s*\*\s*\w)|\bioctl\s*\([^,]*,[^,]*,\s*&" < "$T/all" 2>/dev/null |
awk -v my="$MY32" '{ t = $0   # keep the line only if some sizeof() is not of a plain built-in type
        gsub(/sizeof[ \t]*\([ \t]*(unsigned[ \t]+|signed[ \t]+)?(char|short|int|long|long long|float|double|bool|wchar_t|[Uu]?[Ii]nt(8|16|32|64)_t|size_t|BYTE|WORD|DWORD)[ \t]*\)/, "", t)
        gsub("sizeof[ \t]*\\([ \t]*(" my ")[ \t]*\\)", "", t)
        if (t ~ /sizeof/ || t ~ /ioctl[ \t]*\(/) print }' | clean |
emit REVIEW R8 "Whole structs written to or read from files, sockets, IPC, ioctl" \
"These calls copy a struct's raw bytes across a process or machine boundary. If the struct contains long, size_t, time_t, pointers or a DWORD-style typedef of long (see S5), its layout changed and it no longer matches data written by the old build, 32-bit peers or hardware." \
"Open each struct type listed and check its fields. Use fixed-width types for anything that leaves the process."

src "\(\s*(void|char|unsigned char|caddr_t|[A-Za-z_]\w*)\s*\*\s*\)\s*0[xX]0*[1-9a-fA-F][0-9a-fA-F]{4,}|\b(shmat|mmap|mmap64)\s*\([^,]*0[xX]0*[1-9a-fA-F][0-9a-fA-F]{4,}|^\s*#\s*define\s+\w*(ADDR|ADDRESS|BASE|SHM|SHMEM)\w*\s+\(?\s*(\(\s*[A-Za-z_][^)]*\)\s*)?0[xX]0*[1-9a-fA-F][0-9a-fA-F]{4,}" |
emit REVIEW R9 "Hard-coded addresses (inventory)" \
"Fixed addresses for shared memory and mappings. Listed so you know the full set: they decide which debugging tools can run (ASan reserves 0x7fff8000 and up), and data stored at them is shared across processes." \
"No fix needed by itself; keep this list for tooling decisions."

hdrs "\.\.\.\s*\)\s*(const\s*)?(__attribute__.*|throw\s*\(\s*\)\s*)?;" |
emit REVIEW R10 "Your own variadic functions (inventory)" \
"Functions taking '...'. If any of them ends its argument list with a terminator, add them to GREP64_VARARGS and rerun so S4 checks their calls. If one is a printf-style logger without __attribute__((format(printf, N, M))), adding that attribute makes the compiler check every call's format string." \
"Add the format attribute to printf-style wrappers; add terminator-style functions to GREP64_VARARGS."

srcs "^\s*extern\s+[^;\"(=]*[A-Za-z_]\w*\s*\([^;]*\)\s*;" |
emit REVIEW R11 "Function declared locally with extern instead of via its header" \
"A local declaration can disagree with the real definition. If the function returns a pointer but is declared to return int, the pointer comes back truncated to 32 bits, and C++ name mangling does not catch a wrong return type." \
"Delete the local declaration and include the proper header; if none exists, check the return type against the definition."

# ============================================================ build log
if [ -n "$LOG" ]; then
    sed 's/\x1b\[[0-9;]*[mK]//g' "$LOG" | grep -E '(warning|error):' | sort -u > "$T/log"
    lg() { grep -E -- "$1" "$T/log" | cut -c1-260; }

    lg '\[-Wint-to-pointer-cast\]|cast to pointer from integer of different size|makes pointer from integer without a cast' |
    emit FIX L1 "Build log: integer turned into a pointer" \
    "A value narrower than a pointer (usually an int) is cast to a pointer. If that int ever held a pointer, the top half is gone." \
    "Make the integer intptr_t/uintptr_t all the way back to where the pointer was stored."

    lg '\[-Wpointer-to-int-cast\]|cast from pointer to integer of different size|loses precision|makes integer from pointer without a cast' |
    emit FIX L2 "Build log: pointer turned into a 32-bit integer" \
    "A pointer cast to int/unsigned (a warning in C, or in C++ built with -fpermissive). The top 32 bits are thrown away." \
    "Use uintptr_t / intptr_t, or keep it a pointer."

    lg '\[-Wimplicit-function-declaration\]|implicit declaration of function' |
    emit FIX L3 "Build log: function used without a declaration (C)" \
    "C assumes an undeclared function returns int. If it really returns a pointer (malloc, strdup, getenv, your own functions), the pointer is cut to 32 bits on return." \
    "Include the right header."

    lg '\[-Wreturn-type\]|control reaches end of non-void function|no return statement in function returning non-void' |
    emit FIX L4 "Build log: function can end without returning a value" \
    "The caller gets whatever was left in the return register. On 32-bit x86 that was often the right value by luck; on 64-bit it usually is not." \
    "Add the missing return."

    lg 'expects argument of type [^,]*\*' |
    emit FIX L5 "Build log: printf/scanf format and pointer argument disagree" \
    "Mostly scanf-family calls: e.g. %ld into an int writes 8 bytes into a 4-byte variable and overwrites its neighbour; %d into a long leaves the top half garbage. Also %s given a non-string." \
    "Match the format to the type (%zu for size_t, %ld for long, %p for pointers), or change the variable's type."

    lg '\[-Wsizeof-pointer-memaccess\]|sizeof.*same expression as the destination' |
    emit FIX L6 "Build log: sizeof(pointer) used as a buffer size" \
    "memset(p, 0, sizeof(p)) uses the size of the pointer, which changed from 4 to 8: it now clears or copies 8 bytes, overrunning buffers shorter than that." \
    "Use the buffer's real size, e.g. sizeof(*p) * count."

    lg 'due to limited range of data type' |
    emit FIX L7 "Build log: comparison that can never be true (or false)" \
    "The compiler proved a check is dead, typically a 32-bit variable compared with a 64-bit sentinel." \
    "Widen the variable or fix the constant."

    lg '\[-Woverflow\]' |
    emit FIX L8 "Build log: constant truncated on assignment" \
    "A constant that no longer fits (LONG_MAX, npos, (size_t)-1, a 64-bit mask) is stored into a narrower type." \
    "Use a constant of the destination's size, or widen the destination."

    lg '\[-W(maybe-)?uninitialized\]|is used uninitialized|may be used uninitialized' |
    emit REVIEW L9 "Build log: possibly uninitialized variable" \
    "Stack layout changed in the 64-bit build, so a variable that used to happen to hold 0 or a valid pointer now holds garbage." \
    "Initialize it."

    lg 'shift count >= width of type|shift count is negative|\[-Wshift-count-overflow\]' |
    emit REVIEW L10 "Build log: shift by 32 or more" \
    "Shifting a 32-bit value by 32+ bits is undefined; often a 64-bit mask built from an int (1 << 40)." \
    "Use a 64-bit operand: 1ULL << n."
fi

# ============================================================ print report
{
    echo "grep64 report"
    echo "  source:    $SRC ($nfiles files)"
    if [ -n "$LOG" ]; then echo "  build log: $LOG"; fi
    echo "  generated: $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "FIX  -- each hit is almost always a real bug"
    cat "$T/sum.FIX" 2>/dev/null
    echo
    echo "REVIEW  -- look at each hit; many will be fine"
    cat "$T/sum.REVIEW" 2>/dev/null
    if [ -z "$LOG" ]; then
        echo
        echo "Build-log checks (L1-L10) skipped: build once with -Wall -Wextra and pass the"
        echo "log as the second argument, e.g.  make 2>&1 | tee build.log"
    fi
    cat "$T"/sec.*.FIX 2>/dev/null
    cat "$T"/sec.*.REVIEW 2>/dev/null
}
echo "done." >&2
