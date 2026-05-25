#!/bin/sh

# ==============================================
# laravel-app.sh — Laravel provisioning (runs inside Docker)
# ==============================================
# Invoked by start-project.sh via `docker exec`. Use start-project.sh from your project
# root; this script is not intended to be run directly on the host.
#
# USAGE:
#   ./laravel-app.sh [OPTIONS]
#
# OPTIONS:
#   --no-tailwind     Remove Tailwind from existing projects, or skip it in new projects
#   --add-tailwind    Add Tailwind to existing projects only (new projects get it from the Laravel installer)
#   --ua-template     Download University of Alabama UI component templates (works with new and existing projects)
#
# Persistent volumes (--pv) are configured by start-project.sh on the host before the
# container is built; that flag is not handled here.
#
# EXAMPLES:
#   ./laravel-app.sh
#   ./laravel-app.sh --no-tailwind
#   ./laravel-app.sh --add-tailwind
#   ./laravel-app.sh --ua-template
#
# BEHAVIOR:
#   NEW PROJECT (no app/ directory):
#     - Scaffolds Laravel via the Laravel Installer (Tailwind included by default)
#     - With --no-tailwind: removes Tailwind after scaffolding
#     - Applies full configuration: caching, logging, proxies, session, database, Vite, etc.
#     - Creates README.md template
#
#   EXISTING PROJECT (app/ directory exists):
#     - Installs missing vendor/ or node_modules/ (warns and continues if network fails)
#     - Updates database, Vite, and .gitignore configs only (no full re-scaffold)
#     - Does NOT add or remove Tailwind unless --add-tailwind or --no-tailwind is passed
#     - Does NOT reapply caching/logging/proxy/session (assumes prior setup)
#
# Network-dependent steps log a warning and continue when they fail, as long as the
# required local files already exist.

set -eu

# --------------------------------------
# ⚙️  Configurable Options
# --------------------------------------
# ANSI color codes used for console output formatting
# These define colors for different message types and visual elements
BLUE='\033[1;34m'           # For 📘 (blue book)
BRIGHT_BLUE='\033[1;96m'    # For 🌐 (globe)
GRAY='\033[0;37m'           # For 🗑️ and ⚙️ and 🔧
GREEN='\033[1;32m'          # Success messages
ORANGE='\033[38;5;208m'     # For 📦
PURPLE='\033[38;5;141m'     # For 🗄️ (data cabinet)
RED='\033[1;31m'            # For errors
WHITE='\033[1;37m'          # For main text
YELLOW='\033[1;33m'         # For ⚠️
NC='\033[0m'                # Reset color

# Configuration file paths used throughout the script
# These refer to Laravel configuration files that will be modified
FILE_APP="bootstrap/app.php"
FILE_CACHING="config/cache.php"
FILE_DATABASE="config/database.php"
FILE_LOGGING="config/logging.php"
FILE_SESSION="config/session.php"
FILE_VITE_BASE="vite.config"
LARAVEL_INSTALLER="vendor/laravel/installer/src/NewCommand.php"

# Script behavior flags configured in deploy-plan.json
# Determine whether we should run npm actions (default: true)
# Accepts boolean or string values in deploy-plan.json (e.g. "false" or false)
RUN_NPM=$(php -r "\$d = json_decode(@file_get_contents('deploy-plan.json'), true); \$val = \$d['build']['run_npm'] ?? \$d['run_npm'] ?? null; if(\$val === null) { echo 'true'; } else { if(\$val === false || \$val === 'false') echo 'false'; else echo 'true'; }" | tr -d '\n' | xargs)
# New projects: keep Tailwind from Laravel installer unless --no-tailwind. Existing projects: leave Tailwind alone unless a flag is passed.
TAILWIND=true
TAILWIND_EXPLICIT=false
# Temporary directory for Laravel installer output (will be merged into root)
TEMP_DIR="./new-app"
# UA_TEMPLATE flag controls whether to download University of Alabama templates
UA_TEMPLATE=false

# --------------------------------------
# 🧾 Parse command-line flags
# ------------------------------------- 
# Process command-line arguments to override default behavior
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-tailwind) TAILWIND=false; TAILWIND_EXPLICIT=true; shift ;;
        --add-tailwind) TAILWIND=true; TAILWIND_EXPLICIT=true; shift ;;
        --ua-template) UA_TEMPLATE=true; shift ;;
        *) printf "${RED}❌ Unknown option: $1${NC}\n"; exit 1 ;;
    esac
done

# --------------------------------------
# 🔧 Define functions
# ------------------------------------- 
# Each function below handles a specific configuration task for the Laravel application

# Configure the cache driver in Laravel's cache configuration
# Sets the cache driver to 'file' for persistent file-based caching
function_configure_caching() {
    echo ""
    printf "${PURPLE}🗄️ ${WHITE}Configuring cache driver in '$FILE_CACHING'...${NC}\n"

    if [ -f "$FILE_CACHING" ]; then
        sed -i "s/'default' =>.*/'default' => 'file',/" "$FILE_CACHING"
        printf "${GREEN}✅ Caching updated.${NC}\n"
    else
        printf "${YELLOW}⚠️  Warning: '$FILE_CACHING' not found. Skipping cache configuration.${NC}\n"
    fi
}

# Configure database connection settings based on deploy-plan.json
# Reads database type from deploy-plan.json and updates config/database.php
# Handles Oracle database driver installation if Oracle is configured
function_configure_database() {
    DB_CONNECTION=$(php -r "
        \$databases = json_decode(file_get_contents('deploy-plan.json'), true)['image']['databases'] ?? [];
        echo count(\$databases) > 0 ? \$databases[0] : '';
    ")

    if [ -n "$DB_CONNECTION" ] && [ -f config/database.php ]; then
        echo ""
        printf "${PURPLE}🗄️ ${WHITE}Checking database connection in '$FILE_DATABASE'...${NC}\n"

        # Keep track if anything has changed
        db_config_change=false

        # Read current default DB connection from config/database.php
        current_default=$(grep "'default' => env('DB_CONNECTION'" "$FILE_DATABASE" | sed -E "s/.*'default' => env\('DB_CONNECTION', '([^']*)'\).*/\1/")

        if [ "$current_default" != "$DB_CONNECTION" ]; then
            db_config_change=true
            sed -i "s/'default' => env('DB_CONNECTION', '[^']*')/'default' => env('DB_CONNECTION', '$DB_CONNECTION')/" "$FILE_DATABASE"
            printf "${GREEN}✅ Updated default DB connection in '$FILE_DATABASE' from '$current_default' to '$DB_CONNECTION'.${NC}\n"
        fi

        if php -r "echo json_encode(json_decode(file_get_contents('deploy-plan.json'), true)['image']['databases']);" | grep -q '"oracle"'; then
            # Check if yajra/laravel-oci8 is already installed
            if ! grep -q 'yajra/laravel-oci8' composer.json 2>/dev/null; then
                db_config_change=true

                echo ""
                printf "${ORANGE}📦 ${WHITE}Installing Oracle DB driver...${NC}\n"
                if composer require yajra/laravel-oci8 --no-interaction; then
                    echo ""
                    printf "${GREEN}✅ Oracle driver installed.${NC}\n"
                else
                    echo ""
                    printf "${YELLOW}⚠️  Could not install Oracle driver (network issue?); continuing with existing setup.${NC}\n"
                fi
            fi

            # Only inject the Oracle config block if it's not already there
            if ! grep -q "'oracle' => \[" "$FILE_DATABASE"; then
                db_config_change=true

                echo ""
                printf "${GRAY}🔧 ${WHITE}Injecting Oracle DB configuration...${NC}\n"

                awk '
                    BEGIN { inserted = 0 }
                    /'\''connections'\''[[:space:]]*=>[[:space:]]*\[/ && !inserted {
                        print $0
                        print "        '\''oracle'\'' => ["
                        print "            '\''driver'\''   => '\''oracle'\'',"
                        print "            '\''host'\''     => env('\''DB_HOST'\''),"
                        print "            '\''port'\''     => 1521,"
                        print "            '\''database'\'' => env('\''DB_DATABASE'\''),"
                        print "            '\''service_name'\'' => env('\''DB_SERVICE_NAME'\''),"
                        print "            '\''username'\'' => env('\''DB_USERNAME'\''),"
                        print "            '\''password'\'' => env('\''DB_PASSWORD'\'', '\'''\''),"
                        print "            '\''charset'\''  => '\''utf8'\'',"
                        print "            '\''prefix'\''   => '\'''\'' ,"
                        print "            '\''version'\''  => '\'''\''"
                        print "        ],"
                        inserted = 1
                        next
                    }
                    { print }
                ' "$FILE_DATABASE" > "$FILE_DATABASE".tmp && mv "$FILE_DATABASE".tmp "$FILE_DATABASE"

                printf "${GREEN}✅ Oracle DB config inserted.${NC}\n"
            fi
        fi

        if [ "$db_config_change" = false ]; then
            printf "${GREEN}✅ Database configuration is correct.${NC}\n"
        fi
    fi
}

# Ensure .gitignore file has all standard Laravel exclusions
# Adds missing patterns to prevent tracking of build artifacts, dependencies, and sensitive files
function_configure_gitignore() {
    echo ""
    printf "${GRAY}🗂️  ${WHITE}Ensuring .gitignore has standard exclusions...${NC}\n"
    IGNORE_FILE=".gitignore"

    # Create .gitignore if it doesn't exist
    if [ ! -f "$IGNORE_FILE" ]; then
        touch "$IGNORE_FILE"
        printf "${GREEN}✅ ${WHITE}Created .gitignore file.${NC}\n"
    fi

    # Define all desired ignore patterns in a here-document
    cat <<'EOF' | while IFS= read -r pattern; do
/.composer
/.npm
/.ash_history
/.phpunit.cache
/bootstrap/ssr
/node_modules
/public/build
/public/hot
/public/storage
/storage/*.key
/vendor
.env
.env.backup
.env.production
.phpunit.result.cache
Homestead.json
Homestead.yaml
auth.json
npm-debug.log
yarn-error.log
/.fleet
/.idea
/.vscode
EOF
        # Skip empty lines or comments
        [ -z "$pattern" ] && continue

        if ! grep -qxF "$pattern" "$IGNORE_FILE"; then
            echo "$pattern" >> "$IGNORE_FILE"
            printf "${GREEN}✅ Added ${WHITE}$pattern${GREEN} to .gitignore${NC}\n"
        fi
    done
}

# Configure Laravel's logging system
# Sets up stack-based logging with daily and stderr channels
function_configure_logging() {
    echo ""
    printf "${WHITE}📄 Configuring log settings in '$FILE_LOGGING'...${NC}\n"

    if [ -f "$FILE_LOGGING" ]; then
        sed -i "s/'default' =>.*/'default' => 'stack',/" "$FILE_LOGGING"
        sed -i "/'stack' => \[/,/],/c\\
        'stack' => [\n\
            'driver' => 'stack',\n\
            'channels' => ['daily', 'stderr'],\n\
            'ignore_exceptions' => false,\n\
        ]," "$FILE_LOGGING"

        printf "${GREEN}✅ Logging updated.${NC}\n"
    else
        printf "${YELLOW}⚠️  Warning: '$FILE_LOGGING' not found. Skipping logging configuration.${NC}\n"
    fi
}

# Configure trusted proxy servers in bootstrap/app.php
# Enables Laravel to properly handle requests from proxy servers using internal network IPs
function_configure_proxies() {
    echo ""
    printf "${BRIGHT_BLUE}🌐 ${WHITE}Configuring trusted proxies in '$FILE_APP'...${NC}\n"

    if [ -f "$FILE_APP" ]; then
        sed -i '/\$middleware->trustProxies(at: \[/,/]);/d' "$FILE_APP"
        sed -i '/->withMiddleware.*{/,/})/ {
            /\/\// i\
        $middleware->trustProxies(at: [\
            "10.42.0.0/16",\
            "10.8.0.0/16",\
            "10.1.0.0/16"\
        ]);
        }' "$FILE_APP"

        printf "${GREEN}✅ Trusted proxies updated.${NC}\n"
    else
        printf "${YELLOW}⚠️  Warning: '$FILE_APP' not found. Skipping trusted proxies configuration.${NC}\n"
    fi
}

# Configure the session driver
# Sets session storage to use file-based sessions
function_configure_session() {
    echo ""
    printf "${YELLOW}🔐 ${WHITE}Configuring session driver in '$FILE_SESSION'...${NC}\n"

    if [ -f "$FILE_SESSION" ]; then
        sed -i "s/'driver' =>.*/'driver' => 'file',/" "$FILE_SESSION"
        printf "${GREEN}✅ Session driver updated.${NC}\n"
    else
        printf "${YELLOW}⚠️  Warning: '$FILE_SESSION' not found. Skipping session configuration.${NC}\n"
    fi
}

# Handle Tailwind CSS installation or removal based on TAILWIND flag
# Installs Tailwind if enabled and not already present
# Removes Tailwind if disabled and currently installed
function_configure_tailwind() {
    if [ "$TAILWIND" = false ]; then
        if grep -q '"tailwindcss"' package.json || [ -d node_modules/tailwindcss ]; then
            function_tailwind_remove
        fi
    else
        if ! grep -q '"tailwindcss"' package.json && [ ! -d node_modules/tailwindcss ]; then
            # Tailwind is NOT installed, so install it manually
            function_tailwind_install
        fi
    fi
}

# Configure Vite bundler settings for development and HMR
# Adds server configuration with proper host and Hot Module Replacement settings
function_configure_vite() {
    echo ""
    printf "${GRAY}🛠️ Configuring Vite settings...${NC}\n"

    for FILE_VITE in "$FILE_VITE_BASE.js" "$FILE_VITE_BASE.ts"; do
        if [ ! -f "$FILE_VITE" ]; then
            printf "${YELLOW}⚠️  Warning: '$FILE_VITE' not found. Skipping vite configuration.${NC}\n"
            continue
        fi

        if grep -q 'server:' "$FILE_VITE"; then
            awk '
            BEGIN { in_server=0; host_found=0; hmr_found=0; }
            /server\s*:/ && /\{/ {
                print;
                in_server=1;
                next
            }
            in_server && /host\s*:/ {
                print "        host: '\''0.0.0.0'\'',";
                host_found=1;
                next
            }
            in_server && /hmr\s*:/ {
                print "        hmr: {";
                print "            host: '\''localhost'\''";
                print "        },";
                hmr_found=1;
                # skip original hmr block lines until closing }
                while(getline > 0) {
                    if ($0 ~ /^\s*},?\s*$/) break
                }
                next
            }
            in_server && /\}/ {
                if (!host_found) print "        host: '\''0.0.0.0'\'',"
                if (!hmr_found) {
                    print "        hmr: {"
                    print "            host: '\''localhost'\''"
                    print "        },"
                }
                print
                in_server=0
                next
            }
            { print }
            ' "$FILE_VITE" > "$FILE_VITE.tmp" && mv "$FILE_VITE.tmp" "$FILE_VITE"

            printf "${GREEN}✅ Updated 'server' block in $FILE_VITE${NC}\n"
        else
            sed -i "/^export default defineConfig({/a\\
    server: {\\
        host: '0.0.0.0',\\
        hmr: {\\
            host: 'localhost'\\
        },\\
    },\\
" "$FILE_VITE"

            printf "${GREEN}✅ Added 'server' block to $FILE_VITE${NC}\n"
        fi
    done
}

# Create a template README.md file with sections for application documentation
# Includes placeholders for app title, data sources, integrations, and roles
function_create_readme() {
    echo ""
    printf "${BLUE}📘 ${WHITE}Creating README.md.${NC}\n"

    cat > README.md <<EOL
# Application Title
description of app, be sure to give a rough overview of what the app does.
<br/>
<br/>

## Data Sources
List all data sources this app uses such as

- Database (type: oracle, mysql, azure db, etc.)
- Any API's used (ex Direct Graph API, Jira API, Firewall Ticket API, etc.)
- Any data consumed in flat files
- Any other data that comes into the application from an external source
<br/>
<br/>

## Special Integrations
List any special external integrations this app has such as:

- Touchnet
- onBase
- etc.
<br/>
<br/>

## Roles within the app
Breakdown all the different roles within the app and what access each role has or denote if the app is publicly accessible.
<br/>
<br/>

## Confluence Documentation (Optional)
[Confluence Documentation](https://link-to-confluence-docs.com)
<br/>
<br/>

## Any other notes that may be beneficial to you later on or another developer (optional)
### Some examples

- Any notes on testing the app, either manually or running automated tests
- Any specific pieces of code that you want to draw special attention to, you can use code blocks
\`\`\`php
public function thisFunctionNeedsSpecialAttention()
{

}
\`\`\`
- Any other items you want document
EOL

    printf "${GREEN}✅ README.md created.${NC}\n"
}

# Install and configure Tailwind CSS
# Installs npm packages, creates config files, and adds Tailwind to CSS/Vite
function_tailwind_install() {
    printf "${GRAY}✨ ${WHITE}Installing Tailwind CSS and configs...${NC}\n"

    if [ "$RUN_NPM" = "false" ]; then
        printf "${YELLOW}⚠️  Skipping Tailwind npm install because run_npm=false in deploy-plan.json${NC}\n"
    elif npm install -D tailwindcss postcss autoprefixer @tailwindcss/vite; then
        :
    else
        printf "${YELLOW}⚠️  Tailwind npm install failed (network issue?); continuing with existing packages if present.${NC}\n"
    fi

    # Create tailwind.config.js if missing
    if [ ! -f tailwind.config.js ]; then
        cat > tailwind.config.js <<EOF
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './resources/**/*.blade.php',
    './resources/**/*.js',
    './resources/**/*.vue',
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
EOF
        printf "Created tailwind.config.js\n"
    fi

    # Create postcss.config.js if missing
    if [ ! -f postcss.config.js ]; then
        cat > postcss.config.js <<EOF
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
EOF
        printf "Created postcss.config.js\n"
    fi

    # Add Tailwind directives to CSS file if missing
    if [ -f resources/css/app.css ]; then
        grep -q '@tailwind base;' resources/css/app.css || {
            echo "@tailwind base;" >> resources/css/app.css
            echo "@tailwind components;" >> resources/css/app.css
            echo "@tailwind utilities;" >> resources/css/app.css
            printf "Added Tailwind directives to resources/css/app.css\n"
        }
    fi

    # Add Tailwind directives to SCSS file if missing
    if [ -f resources/sass/app.scss ]; then
        grep -q '@tailwind base;' resources/sass/app.scss || {
            echo "@tailwind base;" >> resources/sass/app.scss
            echo "@tailwind components;" >> resources/sass/app.scss
            echo "@tailwind utilities;" >> resources/sass/app.scss
            printf "Added Tailwind directives to resources/sass/app.scss\n"
        }
    fi

    # Add Tailwind plugin to vite.config.js/ts if missing
    for FILE_VITE in "$FILE_VITE_BASE.js" "$FILE_VITE_BASE.ts"; do
        if [ ! -f "$FILE_VITE" ]; then
            continue
        fi
        if ! grep -q 'tailwindcss' "$FILE_VITE"; then
            sed -i '1i import tailwindcss from "@tailwindcss/vite";' "$FILE_VITE"
            sed -i '/plugins: \[/a \        tailwindcss(),' "$FILE_VITE"
            printf "Added Tailwind plugin to '$FILE_VITE'\n"
        fi
    done

    printf "${GREEN}✅ ${WHITE}Tailwind installed and configured!${NC}\n"
}

# Run composer install to fetch PHP dependencies
# Uses prefer-dist to download pre-built packages for faster installation
function_install_composer() {
    printf "${ORANGE}📦 ${WHITE}Running composer install...${NC}\n"
    if composer install --no-interaction --prefer-dist; then
        printf "${GREEN}✅ Composer dependencies installed.${NC}\n"
    else
        printf "${YELLOW}⚠️  Composer install failed (network issue?); continuing with existing vendor/ if present.${NC}\n"
    fi
}

# Run npm install and npm audit fix for Node.js dependencies
# Respects the RUN_NPM flag from deploy-plan.json to skip if configured
function_install_npm() {
    if [ "$RUN_NPM" = "false" ]; then
        printf "${YELLOW}⚠️  Skipping npm install/audit because run_npm=false in deploy-plan.json${NC}\n"
        return
    fi

    printf "${ORANGE}📦 ${WHITE}Running npm install...${NC}\n"
    if npm install && npm audit fix; then
        printf "${GREEN}✅ NPM dependencies installed.${NC}\n"
    else
        printf "${YELLOW}⚠️  npm install failed (network issue?); continuing with existing node_modules/ if present.${NC}\n"
    fi
}

# Remove Tailwind CSS and related dependencies
# Uninstalls packages, removes config files, cleans CSS/SCSS directives, and prunes node_modules
function_tailwind_remove() {
    printf "${GRAY}🗑️  ${WHITE}Removing Tailwind CSS files and config...${NC}\n"

    # Extract all @tailwindcss packages from package.json in a portable way (no -P)
    tailwind_pkgs=$(grep -o '"@tailwindcss[^"]*"' package.json 2>/dev/null | tr -d '"')
    extra_pkgs="tailwindcss postcss autoprefixer"
    pkgs_to_remove="$tailwind_pkgs $extra_pkgs"

    # Uninstall all identified packages if present
    for pkg in $pkgs_to_remove; do
        if grep -q "\"$pkg\"" package.json 2>/dev/null; then
            if [ "$RUN_NPM" != "false" ]; then
                npm uninstall "$pkg" 2>/dev/null || true
            fi
        fi
    done

    # Remove Tailwind/PostCSS config files if they exist
    [ -f tailwind.config.js ] && rm -f tailwind.config.js
    [ -f postcss.config.js ] && rm -f postcss.config.js

    # Remove Tailwind directives from CSS/SCSS if files exist
    if [ -f resources/css/app.css ]; then
        sed -i '/@tailwind base;/d' resources/css/app.css
        sed -i '/@tailwind components;/d' resources/css/app.css
        sed -i '/@tailwind utilities;/d' resources/css/app.css
        sed -i '/@import.*tailwindcss.*/d' resources/css/app.css
    fi

    if [ -f resources/sass/app.scss ]; then
        sed -i '/@tailwind base;/d' resources/sass/app.scss
        sed -i '/@tailwind components;/d' resources/sass/app.scss
        sed -i '/@tailwind utilities;/d' resources/sass/app.scss
        sed -i '/@import.*tailwindcss.*/d' resources/sass/app.scss
    fi

    # Clean Tailwind plugin lines from vite.config.js/ts if present
    for FILE_VITE in "$FILE_VITE_BASE.js" "$FILE_VITE_BASE.ts"; do
        if [ -f "$FILE_VITE" ] && grep -q 'tailwindcss' "$FILE_VITE"; then
            sed -i '/import.*tailwindcss.*/d' "$FILE_VITE"
            sed -i '/tailwindcss(),/d' "$FILE_VITE"
        fi
    done

    # Remove any leftover Tailwind node_modules folders
    rm -rf node_modules/tailwindcss node_modules/@tailwindcss

    # Prune unused packages from node_modules and update package-lock.json
    if [ "$RUN_NPM" != "false" ]; then
        if npm prune --omit=dev && npm install; then
            :
        else
            printf "${YELLOW}⚠️  npm prune/install failed (network issue?); continuing with existing node_modules/.${NC}\n"
        fi
    else
        printf "${YELLOW}⚠️  Skipping npm prune/install because run_npm=false in deploy-plan.json${NC}\n"
    fi

    printf "${GREEN}✅ ${WHITE}Tailwind removed and dependencies updated.${NC}\n"
}

# Download and add University of Alabama UI component templates
# Pulls pre-built components (navigation, layouts, dropdowns, theme selector, etc.) from GitHub
function_ua_template() {
    if [ "$UA_TEMPLATE" = true ]; then
        echo ""
        printf "${ORANGE}📦 ${WHITE}Downloading UA templates...${NC}\n"
        if wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/NavLinks.php && \
           wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/nav-links.blade.php && \
           wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/VerticalLayout.php && \
           wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/vertical-layout.blade.php && \
           wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/Dropdown.php && \
           wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/dropdown.blade.php && \
           wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/ThemeSelector.php && \
           wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/theme-selector.blade.php && \
           wget --no-check-certificate -nc -P public/img https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/img/nameplate.png; then
            printf "${GREEN}✅ UA templates added.${NC}\n"
        else
            printf "${YELLOW}⚠️  Could not download UA templates (network issue?); continuing without updating templates.${NC}\n"
        fi
    fi
}


# ==============================================
# 🚀 Main Execution
# ==============================================
# Check if this is a fresh Laravel installation or an existing app
# Fresh installs: scaffold new project and apply all configurations
# Existing apps: install missing dependencies and update configs only

if [ ! -d app ]; then
    echo ""
    printf "${ORANGE}🚧 ${WHITE}Starting interactive Laravel scaffolding...${NC}\n"
    # Install Laravel installer package and scaffold new application
    composer require laravel/installer
    if [ "$RUN_NPM" = "false" ]; then
        vendor/bin/laravel new --database=sqlite "$TEMP_DIR"
    else
        vendor/bin/laravel new --database=sqlite --npm "$TEMP_DIR"
    fi

    # Move generated project files from temp directory to workspace root
    printf "${ORANGE}📦 ${WHITE}Moving project files...${NC}\n"
    # This method of moving the application should avoid any file limit issues
    rm -rf vendor composer*
    mv "$TEMP_DIR"/vendor ./
    rm -rf "$TEMP_DIR"/.git*
    find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -exec mv -t . {} +
    rm -rf "$TEMP_DIR"
    printf "\n${GREEN}✅ Project moved!${NC}\n"

    # Fix npm security vulnerabilities (if npm is enabled)
    # Run npm audit fix only when enabled by deploy-plan.json
    if [ "$RUN_NPM" != "false" ]; then
        npm audit fix || true
    else
        printf "${YELLOW}⚠️  Skipping npm audit fix because run_npm=false in deploy-plan.json${NC}\n"
    fi
    
    # Apply all Laravel configuration functions for NEW projects
    # Note: New projects receive ALL configurations (caching, logging, proxies, session, etc.)
    # to ensure a fully optimized setup out of the box
    function_configure_caching
    function_configure_database
    function_configure_logging
    function_configure_proxies
    function_configure_session
    function_configure_tailwind
    function_configure_vite
    function_create_readme
    function_ua_template
    function_configure_gitignore

    printf "\n${GREEN}✅ Laravel scaffolding complete.${NC}\n"
else
    # EXISTING PROJECT MODE
    # For existing Laravel installations, install missing dependencies and update critical configurations
    # This allows you to run the script on an existing project to ensure dependencies are installed
    # and critical configs (database, vite, gitignore) are properly set up
    
    echo ""
    printf "${BRIGHT_BLUE}🌐 ${WHITE}Detected existing Laravel application. Running update mode...${NC}\n"
    
    # Install Node dependencies if not present (and npm is enabled)
    [ "$RUN_NPM" != "false" ] && [ ! -d node_modules ] && function_install_npm
    # Install PHP dependencies if not present
    [ ! -d vendor ] && function_install_composer
    
    # Update critical configuration files for existing installations
    function_configure_database
    function_configure_vite
    # Tailwind: only when explicitly requested on an existing project
    if [ "$TAILWIND_EXPLICIT" = true ]; then
        function_configure_tailwind
    fi
    # Handle UA template downloads for existing projects (if --ua-template flag is set)
    function_ua_template
    function_configure_gitignore

    printf "\n${GREEN}✅ Laravel application updated.${NC}\n"
fi
