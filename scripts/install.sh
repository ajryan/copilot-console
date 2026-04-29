#!/usr/bin/env bash
# Copilot Console - One-click installer for macOS/Linux
# Usage: curl -fsSL https://raw.githubusercontent.com/sanchar10/copilot-console/main/scripts/install.sh | bash
#
# Options (when running as a downloaded file, not via curl|bash):
#   -n, --dry-run                       Print what would happen; make no changes.
#       --assume-dependencies-missing   Pretend deps (python3, node, copilot, rg,
#                                       devtunnel, brew, apt, dnf, yum, sudo, etc.)
#                                       are missing so the "missing dep" message
#                                       branches can be exercised on a fully
#                                       provisioned machine. Implies dry-run-style
#                                       continuation past `die` calls.
#
# Example:
#   bash install.sh --dry-run --assume-dependencies-missing

set -euo pipefail

DRY_RUN=0
ASSUME_DEPS_MISSING=0
while [[ ${#} -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        --assume-dependencies-missing) ASSUME_DEPS_MISSING=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# In dry-run / assume-missing mode, relax `set -e` so subsequent commands that
# depend on a "missing" dependency don't abort the script. We still want to see
# all of the formatted message branches.
if [ "$DRY_RUN" = 1 ] || [ "$ASSUME_DEPS_MISSING" = 1 ]; then
    set +e
    set +o pipefail
fi

REPO="sanchar10/copilot-console"

# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
DRY='\033[0;36m'
NC='\033[0m' # No Color

# --- Dry-run / assume-missing helpers ---

# Run a side-effecting command. First arg is a human-readable description used
# as the dry-run message; remaining args are exec'd directly. Under --dry-run,
# prints the description and returns 0 so `set -e` doesn't abort the script and
# downstream branches still execute.
run() {
    local desc="$1"; shift
    if [ "$DRY_RUN" = 1 ]; then
        printf "  ${DRY}[DRY-RUN]${NC} %s\n" "$desc" >&2
        return 0
    fi
    "$@"
}

# Run a shell-syntax string (pipes, redirections). First arg is a human-readable
# description used as the dry-run message; remaining args are joined and eval'd.
run_sh() {
    local desc="$1"; shift
    if [ "$DRY_RUN" = 1 ]; then
        printf "  ${DRY}[DRY-RUN]${NC} %s\n" "$desc" >&2
        return 0
    fi
    eval "$*"
}

# Returns 1 when --assume-dependencies-missing is set so the "missing dep"
# branches can be exercised on a fully provisioned machine.
have() {
    if [ "$ASSUME_DEPS_MISSING" = 1 ]; then
        return 1
    fi
    command -v "$1" &> /dev/null
}

# Replaces bare `exit N`. Under --dry-run or --assume-dependencies-missing it
# logs and returns 0 so subsequent message-formatting branches keep running.
die() {
    if [ "$DRY_RUN" = 1 ] || [ "$ASSUME_DEPS_MISSING" = 1 ]; then
        printf "  ${DRY}[DRY-RUN]${NC} would exit 1 (continuing to show remaining messages)\n"
        return 0
    fi
    exit 1
}

# Prompt the user with a yes/no question; auto-answers Y under dry-run / assume-missing.
# Usage: prompt_yn "Question? (Y/n)" VAR_NAME
prompt_yn() {
    local question="$1" varname="$2"
    if [ "$DRY_RUN" = 1 ] || [ "$ASSUME_DEPS_MISSING" = 1 ]; then
        printf "  ${DRY}[DRY-RUN]${NC} would prompt: %s (auto-Y)\n" "$question" >&2
        printf -v "$varname" 'Y'
        return
    fi
    if [ -t 0 ] || [ -e /dev/tty ]; then
        read -p "  $question " "$varname" < /dev/tty
    else
        printf -v "$varname" 'Y'
    fi
}

# Compute terminal display width of a string in pure bash. Wide characters
# (CJK, emoji, hourglass etc.) count as 2; ordinary chars count as 1. Ranges
# mirror Get-DisplayWidth in install.ps1.
_disp_width() {
    local s="$1" w=0 ch cp
    while [ -n "$s" ]; do
        ch=${s:0:1}
        cp=$(printf '%d' "'$ch" 2>/dev/null)
        cp=${cp:-0}
        if (( (cp >= 0x1100 && cp <= 0x115F) \
            || (cp >= 0x2329 && cp <= 0x232A) \
            || (cp >= 0x23E9 && cp <= 0x23F3) \
            || (cp >= 0x2600 && cp <= 0x27BF) \
            || (cp >= 0x2E80 && cp <= 0x303E) \
            || (cp >= 0x3041 && cp <= 0x33FF) \
            || (cp >= 0x3400 && cp <= 0x4DBF) \
            || (cp >= 0x4E00 && cp <= 0x9FFF) \
            || (cp >= 0xA000 && cp <= 0xA4CF) \
            || (cp >= 0xAC00 && cp <= 0xD7A3) \
            || (cp >= 0xF900 && cp <= 0xFAFF) \
            || (cp >= 0xFE30 && cp <= 0xFE4F) \
            || (cp >= 0xFF00 && cp <= 0xFF60) \
            || (cp >= 0xFFE0 && cp <= 0xFFE6) \
            || (cp >= 0x1F300 && cp <= 0x1FAFF) )); then
            w=$((w+2))
        else
            w=$((w+1))
        fi
        s=${s:1}
    done
    echo $w
}

# Print one or more lines inside a box, auto-sized to the widest line. Pure
# bash — uses _disp_width to handle wide characters so columns align.
# Usage: boxed [-c COLOR] [-h HEADING] LINE [LINE ...]
boxed() {
    local color="$YELLOW"
    local heading=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c) color="$2"; shift 2 ;;
            -h) heading="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "boxed: unknown option $1" >&2; return 2 ;;
            *)  break ;;
        esac
    done
    local maxw=0 l w
    for l in "$@"; do
        w=$(_disp_width "$l")
        (( w > maxw )) && maxw=$w
    done
    local hseg="" hw=0
    if [ -n "$heading" ]; then
        hseg="─ $heading "
        hw=$(_disp_width "$hseg")
    fi
    local inner=$(( maxw + 4 ))
    (( hw + 2 > inner )) && inner=$(( hw + 2 ))
    local dashes_top=$(( inner - hw ))
    local i top="┌${hseg}"
    for ((i=0; i<dashes_top; i++)); do top+="─"; done
    top+="┐"
    local bot="└"
    for ((i=0; i<inner; i++)); do bot+="─"; done
    bot+="┘"
    printf "%b  %s%b\n" "$color" "$top" "$NC"
    for l in "$@"; do
        w=$(_disp_width "$l")
        local pad_n=$(( inner - 4 - w )) pad=""
        for ((i=0; i<pad_n; i++)); do pad+=" "; done
        printf "%b  │  %s%s  │%b\n" "$color" "$l" "$pad" "$NC"
    done
    printf "%b  %s%b\n" "$color" "$bot" "$NC"
}

echo ""
echo -e "${CYAN}  Copilot Console Installer${NC}"
echo -e "${GRAY}  ====================================${NC}"
echo ""

# --- Preflight: detect ALL missing system dependencies and prompt ONCE ---
# We never silently auto-install. Catalog everything that's missing, ask the
# user once, then either install + exit (asking for re-run) or print manual
# instructions and exit.

# Echoes the OS-specific install command for the named dep, or empty if no
# auto-install is possible (no pkg manager, no sudo, etc.).
_dep_install_cmd() {
    local name="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        case "$name" in
            copilot) echo "npm install -g @github/copilot"; return ;;
        esac
        if have brew; then
            case "$name" in
                curl)    echo "brew install curl" ;;
                python3) echo "brew install python" ;;
                nodejs)  echo "brew install node" ;;
                pipx)    echo "brew install pipx" ;;
                ripgrep) echo "brew install ripgrep" ;;
            esac
        fi
        return
    fi
    case "$name" in
        copilot) echo "npm install -g @github/copilot"; return ;;
    esac
    local mgr="" pkg=""
    if   have apt-get && have sudo; then mgr="apt"
    elif have dnf     && have sudo; then mgr="dnf"
    elif have yum     && have sudo; then mgr="yum"
    fi
    case "$name" in
        curl)    pkg="curl" ;;
        python3) pkg="python3" ;;
        nodejs)  pkg="nodejs npm" ;;
        pipx)    pkg="pipx" ;;
        ripgrep) pkg="ripgrep" ;;
    esac
    case "$mgr" in
        apt) echo "sudo apt-get update -qq && sudo apt-get install -y $pkg" ;;
        dnf) echo "sudo dnf install -y $pkg" ;;
        yum) echo "sudo yum install -y $pkg" ;;
    esac
}

# Echoes manual install instructions for the named dep (one line per echo).
_dep_manual_lines() {
    local name="$1"
    case "$name" in
        curl)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                echo "brew install curl"
                echo "(or: xcode-select --install   # reinstall macOS CLT)"
            else
                echo "sudo apt install curl     # Debian/Ubuntu"
                echo "sudo dnf install curl     # Fedora/RHEL"
            fi ;;
        python3)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                echo "brew install python       # requires Homebrew (https://brew.sh)"
            else
                echo "sudo apt install python3       # Debian/Ubuntu"
                echo "sudo dnf install python3       # Fedora/RHEL"
            fi ;;
        nodejs)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                echo "brew install node"
            else
                echo "sudo apt install nodejs npm    # Debian/Ubuntu"
                echo "sudo dnf install nodejs npm    # Fedora/RHEL"
            fi ;;
        pipx)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                echo "brew install pipx          # requires Homebrew (https://brew.sh)"
                echo "pipx ensurepath"
            else
                echo "sudo apt install pipx          # Debian/Ubuntu (Ubuntu 23.04+)"
                echo "sudo dnf install pipx          # Fedora/RHEL"
                echo "pipx ensurepath"
            fi ;;
        ripgrep)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                echo "brew install ripgrep"
            else
                echo "sudo apt install ripgrep       # Debian/Ubuntu"
                echo "sudo dnf install ripgrep       # Fedora/RHEL"
            fi ;;
        copilot)
            echo "npm install -g @github/copilot"
            echo "(may require sudo if global node_modules is system-owned)" ;;
    esac
}

declare -a MISSING_DEPS=()
have curl    || MISSING_DEPS+=(curl)
have python3 || MISSING_DEPS+=(python3)
have node    || MISSING_DEPS+=(nodejs)
have pipx    || MISSING_DEPS+=(pipx)
have rg      || MISSING_DEPS+=(ripgrep)
have copilot || MISSING_DEPS+=(copilot)

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    declare -a SUMMARY_LINES=()
    declare -a INSTALLABLE=()
    declare -a NOT_INSTALLABLE=()
    for dep in "${MISSING_DEPS[@]}"; do
        cmd=$(_dep_install_cmd "$dep")
        if [ -n "$cmd" ]; then
            SUMMARY_LINES+=("$dep:")
            SUMMARY_LINES+=("    $cmd")
            INSTALLABLE+=("$dep")
        else
            SUMMARY_LINES+=("$dep:  (no auto-install available)")
            NOT_INSTALLABLE+=("$dep")
        fi
    done
    echo -e "${YELLOW}  The following required dependencies are missing.${NC}"
    echo ""
    boxed -h "Missing dependencies — proposed install commands" "${SUMMARY_LINES[@]}"

    print_manual_for_all() {
        for dep in "${MISSING_DEPS[@]}"; do
            echo ""
            local lines=()
            while IFS= read -r line; do lines+=("$line"); done < <(_dep_manual_lines "$dep")
            boxed -h "Install $dep manually" "${lines[@]}"
        done
    }

    if [ ${#INSTALLABLE[@]} -eq 0 ]; then
        echo ""
        echo -e "${RED}  No deps can be auto-installed on this system.${NC}"
        print_manual_for_all
        echo ""
        echo -e "${YELLOW}  After installing, re-run this installer.${NC}"
        die
    fi

    echo ""
    prompt_yn "Install the listed dependencies now? (Y/n)" REPLY
    if [[ "${REPLY:-Y}" =~ ^[Nn] ]]; then
        echo ""
        echo -e "${YELLOW}  Skipping auto-install. Manual instructions below.${NC}"
        print_manual_for_all
        echo ""
        echo -e "${YELLOW}  After installing, re-run this installer.${NC}"
        die
    fi

    echo ""
    echo -e "${CYAN}  Installing missing dependencies...${NC}"
    INSTALL_FAILED=0
    for dep in "${INSTALLABLE[@]}"; do
        cmd=$(_dep_install_cmd "$dep")
        echo -e "${GRAY}  → $dep${NC}"
        run_sh "install $dep: $cmd" "$cmd" || INSTALL_FAILED=1
    done

    if [ ${#NOT_INSTALLABLE[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}  The following deps require manual installation:${NC}"
        for dep in "${NOT_INSTALLABLE[@]}"; do
            echo ""
            lines=()
            while IFS= read -r line; do lines+=("$line"); done < <(_dep_manual_lines "$dep")
            boxed -h "Install $dep manually" "${lines[@]}"
        done
    fi

    echo ""
    if [ "$INSTALL_FAILED" = 1 ]; then
        echo -e "${RED}  One or more installs failed. See output above.${NC}"
    fi
    boxed -c "$GREEN" -h "Next steps" \
        "Dependencies handled. Please re-run this installer to continue:" \
        "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
    if [ "$DRY_RUN" = 1 ] || [ "$ASSUME_DEPS_MISSING" = 1 ]; then
        printf "  ${DRY}[DRY-RUN]${NC} would exit 0 (continuing to show remaining messages)\n"
    else
        exit 0
    fi
fi

# --- Curl safety net (preflight should have handled this) ---
if ! have curl; then
    echo -e "${RED}  [ERROR] curl not found and could not be installed automatically.${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if have brew; then
            boxed -h "What to do" \
                "1. Install curl:  brew install curl" \
                "2. Re-run this installer."
        else
            boxed -h "What to do" \
                "1. curl ships with macOS by default; reinstall the Command Line Tools:" \
                "     xcode-select --install" \
                "2. Re-run this installer."
        fi
    else
        boxed -h "What to do" \
            "1. Install curl:" \
            "     sudo apt install curl   # Debian/Ubuntu" \
            "     sudo dnf install curl   # Fedora/RHEL" \
            "2. Re-run this installer."
    fi
    die
fi

# --- Check Python ---
if ! have python3; then
    echo -e "${RED}  [ERROR] Python 3 not found.${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if have brew; then
            boxed -h "What to do" \
                "1. Install Python:  brew install python" \
                "2. Re-run:" \
                "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
        else
            boxed -h "What to do" \
                "1. Install Homebrew:  https://brew.sh" \
                "2. Install Python:    brew install python" \
                "3. Re-run:" \
                "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
        fi
    else
        boxed -h "What to do" \
            "1. Install Python 3.11+:" \
            "     sudo apt install python3   # Debian/Ubuntu" \
            "     sudo dnf install python3   # Fedora/RHEL" \
            "2. Re-run:" \
            "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
    fi
    die
fi
if have python3; then
    PY_VERSION=$(python3 --version 2>&1 | sed 's/Python //')
    PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
    if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 11 ]; }; then
        echo -e "${RED}  [ERROR] Python 3.11+ required (found $PY_VERSION)${NC}"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if have brew; then
                boxed -h "What to do" \
                    "1. Upgrade Python:  brew install python" \
                    "2. Re-run:" \
                    "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
            else
                boxed -h "What to do" \
                    "1. Install Homebrew:  https://brew.sh" \
                    "2. Install Python:    brew install python" \
                    "3. Re-run:" \
                    "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
            fi
        else
            boxed -h "What to do" \
                "1. Install Python 3.11+:" \
                "     sudo apt install python3   # Debian/Ubuntu" \
                "     sudo dnf install python3   # Fedora/RHEL" \
                "2. Re-run:" \
                "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
        fi
        die
    fi
    echo -e "${GREEN}  [OK] Python $PY_VERSION${NC}"
fi

# --- Check Node.js ---
if ! have node; then
    echo -e "${RED}  [ERROR] Node.js not found.${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if have brew; then
            boxed -h "What to do" \
                "1. Install Node.js:  brew install node" \
                "2. Re-run:" \
                "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
        else
            boxed -h "What to do" \
                "1. Install Homebrew:  https://brew.sh" \
                "2. Install Node.js:   brew install node" \
                "3. Re-run:" \
                "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
        fi
    else
        boxed -h "What to do" \
            "1. Install Node.js 18+:" \
            "     sudo apt install nodejs npm   # Debian/Ubuntu" \
            "     sudo dnf install nodejs npm   # Fedora/RHEL" \
            "2. Re-run:" \
            "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
    fi
    die
fi
if have node; then
    NODE_VERSION=$(node --version 2>&1 | sed 's/v//')
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
    if [ "$NODE_MAJOR" -lt 18 ]; then
        echo -e "${RED}  [ERROR] Node.js 18+ required (found $NODE_VERSION)${NC}"
        boxed -h "What to do" \
            "1. Upgrade Node.js to v18 or newer (https://nodejs.org)" \
            "2. Re-run:" \
            "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
        die
    fi
    echo -e "${GREEN}  [OK] Node.js $NODE_VERSION${NC}"
fi

# --- Copilot CLI safety net (preflight should have handled this) ---
if ! have copilot; then
    echo -e "${RED}  [ERROR] Copilot CLI not found.${NC}"
    boxed -h "What to do" \
        "1. Install manually:  sudo npm install -g @github/copilot" \
        "2. Re-run:" \
        "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
    die
fi
COPILOT_VERSION=$(copilot --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?' || echo "unknown")
echo -e "${GREEN}  [OK] Copilot CLI $COPILOT_VERSION${NC}"

# --- Install Copilot Console ---
echo ""
echo -e "${YELLOW}  Installing Copilot Console...${NC}"
echo ""

# Resolve latest wheel URL from GitHub releases
echo -e "${GRAY}  Fetching latest release...${NC}"
if [ "$DRY_RUN" = 1 ]; then
    run "curl https://api.github.com/repos/$REPO/releases/latest" \
        curl -fsSL -H "User-Agent: copilot-console-installer" \
        "https://api.github.com/repos/$REPO/releases/latest"
    RELEASE_INFO='{"tag_name":"v0.0.0-dryrun","assets":[{"browser_download_url":"https://example.com/copilot_console-0.0.0-py3-none-any.whl"}]}'
else
    RELEASE_INFO=$(curl -fsSL -H "User-Agent: copilot-console-installer" \
        "https://api.github.com/repos/$REPO/releases/latest")
fi
WHL_URL=$(echo "$RELEASE_INFO" | grep -o '"browser_download_url":\s*"[^"]*\.whl"' | head -n1 | cut -d'"' -f4)
if [ -z "$WHL_URL" ]; then
    echo -e "${RED}  [ERROR] No .whl found in latest release.${NC}"
    boxed -h "What to do" \
        "1. Check https://github.com/$REPO/releases" \
        "2. Re-run:" \
        "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
    die
fi
TAG_NAME=$(echo "$RELEASE_INFO" | grep -o '"tag_name":\s*"[^"]*"' | head -n1 | cut -d'"' -f4)
echo -e "${GREEN}  [OK] Found $TAG_NAME${NC}"

echo ""
boxed -c "$YELLOW" "⏳ This may take 5-8 minutes — please wait..."
echo ""

# --- pipx safety net (preflight should have handled this) ---
if ! have pipx; then
    echo -e "${RED}  [ERROR] pipx not available.${NC}"
    boxed -h "What to do" \
        "1. Install pipx manually:" \
        "     sudo apt install pipx          # Debian/Ubuntu" \
        "     sudo dnf install pipx          # Fedora/RHEL" \
        "     brew install pipx              # macOS" \
        "   then run: pipx ensurepath" \
        "2. Re-run:" \
        "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
    die
fi

INSTALLED=false
if [ "$DRY_RUN" = 1 ]; then
    run "pipx install --force $WHL_URL" pipx install --force "$WHL_URL"
    INSTALLED=true
else
    PIPX_OUTPUT=$(pipx install --force "$WHL_URL" 2>&1)
    PIPX_EXIT=$?
    if [ $PIPX_EXIT -eq 0 ]; then
        echo "$PIPX_OUTPUT" | grep -vE 'symlink|These apps' | grep -v '^$' | sed 's/^/  /' | sed "s/.*/  ${GRAY}&${NC}/"
        INSTALLED=true
    else
        echo -e "${RED}  [ERROR] pipx install failed.${NC}"
        echo "$PIPX_OUTPUT" | sed 's/^/    /'
    fi
fi
# Clean up stale dist-info directories that confuse importlib.metadata
INSTALLED_VERSION="${TAG_NAME#v}"
SITE_DIR=$(python3 -c "import site; print(site.getusersitepackages())" 2>/dev/null)
if [ -n "$INSTALLED_VERSION" ] && [ -n "$SITE_DIR" ] && [ -d "$SITE_DIR" ]; then
    for old_dist in "$SITE_DIR"/copilot_console-*.dist-info; do
        [ -d "$old_dist" ] || continue
        case "$old_dist" in
            *"copilot_console-${INSTALLED_VERSION}.dist-info") ;; # keep current
            *) rm -rf "$old_dist" 2>/dev/null ;;
        esac
    done
fi

if [ "$INSTALLED" = false ]; then
    boxed -h "What to do" \
        "1. Try installing manually:" \
        "     pipx install --force \"$WHL_URL\"" \
        "2. Re-run:" \
        "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
    die
fi

# --- Verify ---
# Ensure pipx-managed shims dir (~/.local/bin) is in PATH
PATH_MODIFIED=false
SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

# If no SHELL_RC found, check .bash_profile (macOS default for bash) and .profile
if [ -z "$SHELL_RC" ]; then
    if [ -f "$HOME/.bash_profile" ]; then
        SHELL_RC="$HOME/.bash_profile"
    elif [ -f "$HOME/.profile" ]; then
        SHELL_RC="$HOME/.profile"
    fi
fi

# Linux: ~/.local/bin
if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$PATH:$HOME/.local/bin"
    if [ -n "$SHELL_RC" ] && ! grep -q '\.local/bin' "$SHELL_RC" 2>/dev/null; then
        run_sh "append PATH export to $SHELL_RC" "echo 'export PATH=\"\$PATH:\$HOME/.local/bin\"' >> \"$SHELL_RC\""
        echo -e "${GREEN}  [OK] Added ~/.local/bin to PATH in $(basename $SHELL_RC)${NC}"
        PATH_MODIFIED=true
    fi
fi

# macOS: ~/Library/Python/X.Y/bin
if [[ "$OSTYPE" == "darwin"* ]]; then
    MAC_PY_BIN="$HOME/Library/Python/$PY_MAJOR.$PY_MINOR/bin"
    if [ -d "$MAC_PY_BIN" ] && [[ ":$PATH:" != *":$MAC_PY_BIN:"* ]]; then
        export PATH="$PATH:$MAC_PY_BIN"
        if [ -n "$SHELL_RC" ] && ! grep -q 'Library/Python' "$SHELL_RC" 2>/dev/null; then
            run_sh "append $MAC_PY_BIN PATH export to $SHELL_RC" "echo 'export PATH=\"\$PATH:$MAC_PY_BIN\"' >> \"$SHELL_RC\""
            echo -e "${GREEN}  [OK] Added $MAC_PY_BIN to PATH in $(basename $SHELL_RC)${NC}"
            PATH_MODIFIED=true
        fi
    fi
fi

# Fish shell support
FISH_CONFIG="$HOME/.config/fish/config.fish"
if [ -f "$FISH_CONFIG" ]; then
    # For ~/.local/bin
    if [ -d "$HOME/.local/bin" ] && ! grep -q '.local/bin' "$FISH_CONFIG" 2>/dev/null; then
        run_sh "append PATH set to config.fish" "echo 'set -gx PATH \$PATH \$HOME/.local/bin' >> \"$FISH_CONFIG\""
        echo -e "${GREEN}  [OK] Added ~/.local/bin to PATH in config.fish${NC}"
        PATH_MODIFIED=true
    fi
    # For macOS pip bin
    if [[ "$OSTYPE" == "darwin"* ]] && [ -d "$MAC_PY_BIN" ] && ! grep -q 'Library/Python' "$FISH_CONFIG" 2>/dev/null; then
        run_sh "append $MAC_PY_BIN PATH set to config.fish" "echo 'set -gx PATH \$PATH $MAC_PY_BIN' >> \"$FISH_CONFIG\""
        echo -e "${GREEN}  [OK] Added $MAC_PY_BIN to PATH in config.fish${NC}"
        PATH_MODIFIED=true
    fi
fi

if have copilot-console; then
    AC_VERSION=$(copilot-console --version 2>&1)
    echo -e "${GREEN}  [OK] $AC_VERSION${NC}"
else
    echo -e "${GREEN}  [OK] Installed${NC}"
    echo -e "${YELLOW}  [NOTE] Restart your terminal, then run 'copilot-console'.${NC}"
fi

# --- ripgrep safety net (preflight should have handled this) ---
if ! have rg; then
    echo ""
    echo -e "${YELLOW}  [WARN] ripgrep not installed. Cross-session content search will not work.${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e "${YELLOW}     Install manually: brew install ripgrep${NC}"
    else
        echo -e "${YELLOW}     Install manually: sudo apt install ripgrep   # (or dnf/yum)${NC}"
    fi
else
    RG_VERSION=$(rg --version 2>&1 | head -n1)
    echo -e "${GREEN}  [OK] $RG_VERSION${NC}"
fi

# --- Optional: Agentic Web Browsing (Playwright MCP) ---
echo ""
echo -e "${CYAN}  Optional: Agentic Web Browsing${NC}"
echo -e "${GRAY}  Adds autonomous web navigation via Playwright MCP server.${NC}"
echo -e "${GRAY}  Uses your system browser (Edge or Chrome).${NC}"
echo ""
prompt_yn "Enable agentic web browsing? (Y/n)" SETUP_PLAYWRIGHT
if [[ ! "$SETUP_PLAYWRIGHT" =~ ^[Nn]$ ]]; then
    MCP_CONFIG_PATH="$HOME/.copilot-console/mcp-config.json"
    ADD_PLAYWRIGHT=true
    if [ -f "$MCP_CONFIG_PATH" ]; then
        if grep -q '"playwright"' "$MCP_CONFIG_PATH" 2>/dev/null; then
            echo -e "${GREEN}  [OK] Playwright MCP server already configured${NC}"
            ADD_PLAYWRIGHT=false
        fi
    fi
    if [ "$ADD_PLAYWRIGHT" = true ]; then
        run "mkdir -p $(dirname "$MCP_CONFIG_PATH")" mkdir -p "$(dirname "$MCP_CONFIG_PATH")"
        if [ "$DRY_RUN" = 1 ]; then
            run "write Playwright entry to $MCP_CONFIG_PATH" \
                sh -c "cat > '$MCP_CONFIG_PATH'"
        elif [ -f "$MCP_CONFIG_PATH" ]; then
            # Update existing config (basic jq-free approach)
            TEMP_CONFIG=$(mktemp)
            python3 -c "
import json, sys
with open('$MCP_CONFIG_PATH', 'r') as f:
    config = json.load(f)
if 'mcpServers' not in config:
    config['mcpServers'] = {}
config['mcpServers']['playwright'] = {
    'type': 'local',
    'command': 'npx',
    'tools': ['*'],
    'args': ['@playwright/mcp@latest']
}
with open('$TEMP_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null && mv "$TEMP_CONFIG" "$MCP_CONFIG_PATH"
        else
            # Create new config
            cat > "$MCP_CONFIG_PATH" << 'EOF'
{
  "mcpServers": {
    "playwright": {
      "type": "local",
      "command": "npx",
      "tools": ["*"],
      "args": ["@playwright/mcp@latest"]
    }
  }
}
EOF
        fi
        echo -e "${GREEN}  [OK] Playwright MCP server added to config${NC}"
    fi
else
    echo -e "${GRAY}  Skipped. Enable later — see docs/guides/INSTALL.md${NC}"
fi

# --- Optional: Mobile Access & CLI Notifications ---
MOBILE_ENABLED=false
echo ""
echo -e "${CYAN}  Optional: Mobile Access & CLI Notifications${NC}"
echo -e "${GRAY}  Access sessions from your phone, get push notifications when${NC}"
echo -e "${GRAY}  any Copilot CLI session finishes. Requires devtunnel.${NC}"
echo ""
prompt_yn "Enable mobile access & notifications? (Y/n)" SETUP_MOBILE
if [[ ! "$SETUP_MOBILE" =~ ^[Nn]$ ]]; then
    # Enable CLI notifications
    if have cli-notify; then
        run "cli-notify on" cli-notify on
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}  [OK] CLI notifications enabled${NC}"
        else
            echo -e "${YELLOW}  [WARN] Failed to enable. Run 'cli-notify on' manually.${NC}"
        fi
    else
        echo -e "${YELLOW}  [WARN] cli-notify not found. Restart terminal and run 'cli-notify on'.${NC}"
    fi

    # Install devtunnel
    if ! have devtunnel; then
        echo -e "${YELLOW}  Installing devtunnel...${NC}"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS — try brew first, then direct binary download
            if have brew; then
                run "brew install --cask devtunnel" brew install --cask devtunnel
            fi
            if ! have devtunnel; then
                # Download standalone binary
                local dt_dir="$HOME/.local/bin"
                mkdir -p "$dt_dir"
                local arch=$(uname -m)
                local dt_url="https://aka.ms/TunnelsCliDownload/osx-x64"
                if [[ "$arch" == "arm64" ]]; then
                    dt_url="https://aka.ms/TunnelsCliDownload/osx-arm64"
                fi
                echo -e "${YELLOW}  Downloading devtunnel binary...${NC}"
                run_sh "download devtunnel binary from $dt_url" "curl -sL '$dt_url' -o '$dt_dir/devtunnel' && chmod +x '$dt_dir/devtunnel'"
                if [[ ":$PATH:" != *":$dt_dir:"* ]]; then
                    export PATH="$PATH:$dt_dir"
                fi
            fi
        else
            # Linux — use official Microsoft installer (downloads binary directly)
            run_sh "curl -sL https://aka.ms/DevTunnelCliInstall | bash" "curl -sL https://aka.ms/DevTunnelCliInstall 2>/dev/null | bash &> /dev/null || true"
            # The installer may place devtunnel in ~/bin or ~/.local/bin — ensure they're in PATH
            for p in "$HOME/bin" "$HOME/.local/bin"; do
                if [ -f "$p/devtunnel" ] && [[ ":$PATH:" != *":$p:"* ]]; then
                    export PATH="$PATH:$p"
                fi
            done
        fi
        if ! have devtunnel; then
            echo -e "${RED}  [ERROR] Failed to install devtunnel.${NC}"
            boxed -h "What to do" \
                "1. Install manually:" \
                "     https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/get-started" \
                "2. Re-run:" \
                "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
        fi
    fi
    if have devtunnel; then
        echo -e "${GREEN}  [OK] devtunnel installed${NC}"
        MOBILE_ENABLED=true
        echo -e "${YELLOW}  [NOTE] Run 'devtunnel user login' to authenticate before first use.${NC}"
        echo -e "${GRAY}  TIP: Use a work or school (Entra ID) account for best iOS/Safari support.${NC}"
    fi
else
    echo -e "${GRAY}  Skipped. Enable later with 'cli-notify on' or see docs/guides/MOBILE-COMPANION.md${NC}"
fi

# --- Done ---
echo ""
if [ "$MOBILE_ENABLED" = true ]; then
    echo -e "${CYAN}  Ready! Complete mobile setup:${NC}"
    echo ""
    echo -e "    1. Run:  devtunnel user login"
    echo -e "    2. Run:  copilot-console --expose --no-sleep"
    echo -e "    3. Open Settings -> scan QR code on your phone"
    echo -e "    4. Install as PWA when prompted"
    echo -e "    5. Allow notifications when the browser asks"
    echo ""
    echo -e "${GRAY}  After this, CLI notifications work automatically.${NC}"
else
    echo -e "${CYAN}  Ready! Run 'copilot-console' to start.${NC}"
    if [ "$PATH_MODIFIED" = true ]; then
        echo -e "${YELLOW}  [NOTE] Run 'source ~/${SHELL_RC##*/}' or open a new terminal if command is not found.${NC}"
    fi
fi
echo ""
