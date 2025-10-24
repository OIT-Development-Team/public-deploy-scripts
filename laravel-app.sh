#!/bin/sh

set -eu

# --------------------------------------
# ⚙️  Configurable Options
# --------------------------------------
# ANSI color definitions
BLUE='\033[1;34m'			# For 📘 (blue book)
BRIGHT_BLUE='\033[1;96m'	# For 🌐 (globe)
GRAY='\033[0;37m'			# For 🗑️ and ⚙️ and 🔧
GREEN='\033[1;32m'			# Success messages
ORANGE='\033[38;5;208m'		# For 📦
PURPLE='\033[38;5;141m'     # For 🗄️ (data cabinet)
RED='\033[1;31m'			# For errors
WHITE='\033[1;37m'			# For main text
YELLOW='\033[1;33m'			# For ⚠️
NC='\033[0m'				# Reset color

# Variables
FILE_APP="bootstrap/app.php"
FILE_CACHING="config/cache.php"
FILE_DATABASE="config/database.php"
FILE_LOGGING="config/logging.php"
FILE_SESSION="config/session.php"
FILE_VITE_BASE="vite.config"
LARAVEL_INSTALLER="vendor/laravel/installer/src/NewCommand.php"
TAILWIND=true
TEMP_DIR="./new-app"
UA_TEMPLATE=false

# --------------------------------------
# 🧾 Parse command-line flags
# --------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pv) shift ;;
        --no-tailwind) TAILWIND=false; shift ;;
        --ua-template) UA_TEMPLATE=true; shift ;;
        *) printf "${RED}❌ Unknown option: $1${NC}\n"; exit 1 ;;
    esac
done

# --------------------------------------
# 🔧 Define functions
# --------------------------------------
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
        	    composer require yajra/laravel-oci8 --no-interaction
        	    echo ""
        	    printf "${GREEN}✅ Oracle driver installed.${NC}\n"
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

function_configure_gitignore() {
    echo ""
    printf "${GRAY}🗂️  ${WHITE}Ensuring .gitignore has standard exclusions...${NC}\n"
    IGNORE_FILE=".gitignore"

    # Create .gitignore if it doesn't exist
    [ ! -f "$IGNORE_FILE" ] && touch "$IGNORE_FILE"

    # Define all desired ignore patterns
    patterns=(
        "/.composer"
        "/.npm"
        "/.ash_history"
        "/.phpunit.cache"
        "/bootstrap/ssr"
        "/node_modules"
        "/public/build"
        "/public/hot"
        "/public/storage"
        "/storage/*.key"
        "/vendor"
        ".env"
        ".env.backup"
        ".env.production"
        ".phpunit.result.cache"
        "Homestead.json"
        "Homestead.yaml"
        "auth.json"
        "npm-debug.log"
        "yarn-error.log"
        "/.fleet"
        "/.idea"
        "/.vscode"
    )

    # Append each pattern if it's not already in .gitignore
    for pattern in "${patterns[@]}"; do
        if ! grep -qxF "$pattern" "$IGNORE_FILE"; then
            echo "$pattern" >> "$IGNORE_FILE"
            printf "${GREEN}✅ Added ${WHITE}$pattern${GREEN} to .gitignore${NC}\n"
        fi
    done
}

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

function_tailwind_install() {
    printf "${GRAY}✨ ${WHITE}Installing Tailwind CSS and configs...${NC}\n"

    # Install Tailwind-related packages and update node_modules
    npm install -D tailwindcss postcss autoprefixer @tailwindcss/vite

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

    # Add Tailwind plugin to vite.config.js if missing
    if [ -f "$FILE_VITE" ]; then
        if ! grep -q 'tailwindcss' "$FILE_VITE"; then
            # Insert import at the top after other imports
            sed -i '1i import tailwindcss from "@tailwindcss/vite";' "$FILE_VITE"

            # Add tailwindcss() to plugins array (naive approach)
            sed -i '/plugins: \[/a \        tailwindcss(),' "$FILE_VITE"

            printf "Added Tailwind plugin to '$FILE_VITE'\n"
        fi
    fi

    printf "${GREEN}✅ ${WHITE}Tailwind installed and configured!${NC}\n"
}

function_install_composer() {
    printf "${ORANGE}📦 ${WHITE}Running composer install...${NC}\n"
    composer install --no-interaction --prefer-dist || true
    printf "${GREEN}✅ Composer dependencies installed.${NC}\n"
}

function_install_npm() {
    printf "${ORANGE}📦 ${WHITE}Running npm install...${NC}\n"
    npm install || true
    npm audit fix || true
    printf "${GREEN}✅ NPM dependencies installed.${NC}\n"
}

function_tailwind_remove() {
    printf "${GRAY}🗑️  ${WHITE}Removing Tailwind CSS files and config...${NC}\n"

    # Extract all @tailwindcss packages from package.json in a portable way (no -P)
    tailwind_pkgs=$(grep -o '"@tailwindcss[^"]*"' package.json 2>/dev/null | tr -d '"')
    extra_pkgs="tailwindcss postcss autoprefixer"
    pkgs_to_remove="$tailwind_pkgs $extra_pkgs"

    # Uninstall all identified packages if present
    for pkg in $pkgs_to_remove; do
        if grep -q "\"$pkg\"" package.json 2>/dev/null; then
            npm uninstall "$pkg" 2>/dev/null || true
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

    # Clean Tailwind plugin lines from vite.config.js if present
    if [ -f "$FILE_VITE" ]; then
        if grep -q 'tailwindcss' "$FILE_VITE"; then
            sed -i '/import.*tailwindcss.*/d' "$FILE_VITE"
            sed -i '/tailwindcss(),/d' "$FILE_VITE"
        fi
    fi

    # Remove any leftover Tailwind node_modules folders
    rm -rf node_modules/tailwindcss node_modules/@tailwindcss

    # Prune unused packages from node_modules and update package-lock.json
    npm prune --omit=dev
    npm install

    printf "${GREEN}✅ ${WHITE}Tailwind removed and dependencies updated.${NC}\n"
}

function_ua_template() {
	if [ "$UA_TEMPLATE" = true ]; then
    	echo ""
    	printf "${ORANGE}📦 ${WHITE}Downloading UA templates...${NC}\n"
    	wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/NavLinks.php && \
    	wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/nav-links.blade.php && \
    	wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/VerticalLayout.php && \
    	wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/vertical-layout.blade.php && \
    	wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/Dropdown.php && \
    	wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/dropdown.blade.php
    	wget --no-check-certificate -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/ThemeSelector.php && \
    	wget --no-check-certificate -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/theme-selector.blade.php
    	wget --no-check-certificate -nc -P public/img https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/img/nameplate.png
		printf "${GREEN}✅ UA templates added.${NC}\n"
	fi
}


# --------------------------------------
# 🚀 Main Execution
# --------------------------------------

if [ ! -d app ]; then
    echo ""
    printf "${ORANGE}🚧 ${WHITE}Starting interactive Laravel scaffolding...${NC}\n"
    composer require laravel/installer
    vendor/bin/laravel new --database=sqlite --npm "$TEMP_DIR"

	printf "${ORANGE}📦 ${WHITE}Moving project files...${NC}\n"
	# This method of moving the application should avoid any file limit issues
	rm -rf vendor composer*
    mv "$TEMP_DIR"/vendor ./
	rm -rf "$TEMP_DIR"/.git*
    find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -exec mv -t . {} +
    rm -rf "$TEMP_DIR"
	printf "\n${GREEN}✅ Project moved!${NC}\n"

	npm audit fix
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

    echo ""
    printf "\n${GREEN}✅ Laravel scaffolding complete.${NC}\n"
else
    [ ! -d node_modules ] && function_install_npm
    [ ! -d vendor ] && function_install_composer
    function_configure_database
    function_configure_vite
    function_configure_gitignore

    printf "\n${GREEN}✅ Laravel application already exists.${NC}\n"
fi
