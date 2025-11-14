#!/bin/sh

set -eu

# --------------------------------------
# ⚙️  Configurable Options
# --------------------------------------
# ANSI color definitions
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
    # Get database connection from deploy-plan.json
    php_script=$(mktemp)
    cat > "$php_script" <<-'PHP_SCRIPT'
		<?php
		$databases = json_decode(file_get_contents('deploy-plan.json'), true)['image']['databases'] ?? [];
		echo count($databases) > 0 ? $databases[0] : '';
	PHP_SCRIPT

    DB_CONNECTION=$(php "$php_script")
    rm -f "$php_script"

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

        # Check if Oracle is in the database list
        php_script=$(mktemp)
        cat > "$php_script" <<-'PHP_SCRIPT'
			<?php
			echo json_encode(json_decode(file_get_contents('deploy-plan.json'), true)['image']['databases']);
		PHP_SCRIPT

        if php "$php_script" | grep -q '"oracle"'; then
            rm -f "$php_script"
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

                awk_script=$(mktemp)
                cat > "$awk_script" <<-'AWK_SCRIPT'
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
				AWK_SCRIPT

                awk -f "$awk_script" "$FILE_DATABASE" > "$FILE_DATABASE".tmp && mv "$FILE_DATABASE".tmp "$FILE_DATABASE"
                rm -f "$awk_script"

                printf "${GREEN}✅ Oracle DB config inserted.${NC}\n"
            fi
        else
            # Clean up temp file if Oracle check was false
            rm -f "$php_script"
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
    if [ ! -f "$IGNORE_FILE" ]; then
        touch "$IGNORE_FILE"
        printf "${GREEN}✅ ${WHITE}Created .gitignore file.${NC}\n"
    fi

    # Define all desired ignore patterns in a here-document
    cat <<-'EOF' | while IFS= read -r pattern; do
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

function_configure_logging() {
    echo ""
    printf "${WHITE}📄 Configuring log settings in '$FILE_LOGGING'...${NC}\n"

    if [ -f "$FILE_LOGGING" ]; then
        sed -i "s/'default' =>.*/'default' => 'stack',/" "$FILE_LOGGING"
        
        # Replace stack configuration
        sed_script=$(mktemp)
        cat > "$sed_script" <<-'SED_SCRIPT'
			/'stack' => \[/,/],/c\
		'stack' => [\
		    'driver' => 'stack',\
		    'channels' => ['daily', 'stderr'],\
		    'ignore_exceptions' => false,\
		],
		SED_SCRIPT

        sed -i -f "$sed_script" "$FILE_LOGGING"
        rm -f "$sed_script"

        printf "${GREEN}✅ Logging updated.${NC}\n"
    else
        printf "${YELLOW}⚠️  Warning: '$FILE_LOGGING' not found. Skipping logging configuration.${NC}\n"
    fi
}

function_configure_proxies() {
    echo ""
    printf "${BRIGHT_BLUE}🌐 ${WHITE}Configuring trusted proxies in '$FILE_APP'...${NC}\n"

    if [ -f "$FILE_APP" ]; then
        sed_script=$(mktemp)
        cat > "$sed_script" <<-'SED_SCRIPT'
			/\$middleware->trustProxies(at: \[/,/]);/d
			/->withMiddleware.*{/,/})/ {
			    /\/\// i\
			$middleware->trustProxies(at: [\
			    "10.42.0.0/16",\
			    "10.8.0.0/16",\
			    "10.1.0.0/16"\
			]);
			}
		SED_SCRIPT

        sed -i -f "$sed_script" "$FILE_APP"
        rm -f "$sed_script"

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
            function_remove_tailwind
        fi
    else
        if ! grep -q '"tailwindcss"' package.json && [ ! -d node_modules/tailwindcss ]; then
            # Tailwind is NOT installed, so install it manually
            function_install_tailwind
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
            # Create temporary awk script for better readability
            # Use octal escape \047 for single quotes to avoid shell escaping issues
            awk_script=$(mktemp)
            cat > "$awk_script" <<-'AWK_SCRIPT'
				BEGIN { in_server=0; host_found=0; hmr_found=0; watch_found=0; }
				/server\s*:/ && /\{/ {
				    print "    server: {";
				    in_server=1;
				    next
				}
				in_server && /host\s*:/ {
				    print "        host: \0470.0.0.0\047,";
				    host_found=1;
				    next
				}
				in_server && /hmr\s*:/ {
				    print "        hmr: {";
				    print "            host: \047localhost\047";
				    print "        },";
				    hmr_found=1;
				    # skip original hmr block lines until closing }
				    while(getline > 0) {
				        if ($0 ~ /^\s*},?\s*$/) break
				    }
				    next
				}
				in_server && /watch\s*:/ {
				    watch_found=1;
				    # skip original watch block lines until closing }
				    while(getline > 0) {
				        if ($0 ~ /^\s*},?\s*$/) break
				    }
				    next
				}
				in_server && /\}/ {
				    if (!host_found) print "        host: \0470.0.0.0\047,"
				    if (!hmr_found) {
				        print "        hmr: {"
				        print "            host: \047localhost\047"
				        print "        },"
				    }
				    if (!watch_found) {
				        print "        watch: {"
				        print "          ignored: [\047**/vendor/**\047, \047**/storage/**\047, \047**/node_modules/**\047]"
				        print "        }"
				    }
				    print "    },"
				    in_server=0
				    next
				}
				{ print }
			AWK_SCRIPT

            awk -f "$awk_script" "$FILE_VITE" > "$FILE_VITE.tmp" && mv "$FILE_VITE.tmp" "$FILE_VITE"
            rm -f "$awk_script"

            printf "${GREEN}✅ Updated 'server' block in $FILE_VITE${NC}\n"
        else
            # Add server block after defineConfig
            # Using inline sed because sed script files don't handle multi-line a\ well
            sed -i "/^export default defineConfig({/a\\
    server: {\\
        host: '0.0.0.0',\\
        hmr: {\\
            host: 'localhost'\\
        },\\
        watch: {\\
          ignored: ['**/vendor/**', '**/storage/**', '**/node_modules/**']\\
        }\\
    },\\
" "$FILE_VITE"

            printf "${GREEN}✅ Added 'server' block to $FILE_VITE${NC}\n"
        fi
    done
}

function_create_readme() {
    echo ""
    printf "${BLUE}📘 ${WHITE}Creating README.md.${NC}\n"

    cat > README.md <<-EOL
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

function_install_browser_testing() {
    echo ""
    printf "${ORANGE}🧪 ${WHITE}Setting up browser testing with Pest v4...${NC}\n"

    # Check if Pest browser plugin is installed
    if grep -q 'pestphp/pest-plugin-browser' composer.json 2>/dev/null; then
        pest_installed=true
    else
        pest_installed=false
    fi

    # Check if Playwright is installed in package.json
    if grep -q 'playwright' package.json 2>/dev/null; then
        playwright_installed=true
    else
        playwright_installed=false
    fi

    # Install Pest browser plugin if not present
    if [ "$pest_installed" = false ]; then
        printf "${GRAY}   Installing Pest browser plugin...${NC}\n"
        composer require pestphp/pest-plugin-browser --dev --no-interaction
        printf "${GREEN}✅ Pest browser plugin installed.${NC}\n"
    else
        printf "${GREEN}✅ Pest browser plugin already installed.${NC}\n"
    fi

    # Install Playwright if not present
    if [ "$playwright_installed" = false ]; then
        printf "${GRAY}   Installing Playwright...${NC}\n"
        npm install playwright@latest
        printf "${GREEN}✅ Playwright installed.${NC}\n"
    else
        printf "${GREEN}✅ Playwright already installed.${NC}\n"
    fi

    # Install Playwright browsers (only if not already installed)
    # Check if Chromium is already installed by looking for the cache directory
    PLAYWRIGHT_CACHE_CHECK=""
    if [ -d "$PWD/.cache/ms-playwright" ]; then
        PLAYWRIGHT_CACHE_CHECK="$PWD/.cache/ms-playwright"
    elif [ -d "/var/www/html/.cache/ms-playwright" ]; then
        PLAYWRIGHT_CACHE_CHECK="/var/www/html/.cache/ms-playwright"
    elif [ -d "$HOME/.cache/ms-playwright" ]; then
        PLAYWRIGHT_CACHE_CHECK="$HOME/.cache/ms-playwright"
    fi

    CHROMIUM_INSTALLED=false
    if [ -n "$PLAYWRIGHT_CACHE_CHECK" ] && [ -d "$PLAYWRIGHT_CACHE_CHECK" ]; then
        # Check if chromium_headless_shell directory exists
        if find "$PLAYWRIGHT_CACHE_CHECK" -type d -name "chromium_headless_shell-*" 2>/dev/null | head -1 | grep -q .; then
            CHROMIUM_INSTALLED=true
        fi
    fi

    if [ "$CHROMIUM_INSTALLED" = false ]; then
        printf "${GRAY}   Installing Playwright browsers...${NC}\n"
        npx playwright install chromium 2>/dev/null || true
        printf "${GREEN}✅ Playwright browsers installed.${NC}\n"
    else
        printf "${GREEN}✅ Playwright browsers already installed.${NC}\n"
    fi

    # Configure phpunit.xml to include Browser testsuite
    if [ -f phpunit.xml ]; then
        printf "${GRAY}   Configuring phpunit.xml...${NC}\n"
        
        # Check if Browser testsuite already exists
        if ! grep -q '<testsuite name="Browser">' phpunit.xml; then
            # Add Browser testsuite after Feature testsuite using awk
            awk_script=$(mktemp)
            cat > "$awk_script" <<-'AWK_SCRIPT'
				/<testsuite name="Feature">/,/<\/testsuite>/ {
				    print
				    if (/<\/testsuite>/) {
				        print "        <testsuite name=\"Browser\">"
				        print "            <directory>tests/Browser</directory>"
				        print "        </testsuite>"
				    }
				    next
				}
				{ print }
			AWK_SCRIPT

            awk -f "$awk_script" phpunit.xml > phpunit.xml.tmp && mv phpunit.xml.tmp phpunit.xml
            rm -f "$awk_script"
            
            # Add Playwright environment variables to php section
            sed_script=$(mktemp)
            if grep -q '<env name="NIGHTWATCH_ENABLED"' phpunit.xml; then
                cat > "$sed_script" <<-'SED_SCRIPT'
					/<env name="NIGHTWATCH_ENABLED"/a\
			<env name="PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD" value="1"/>\
			<env name="PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" value="/usr/bin/chromium-browser"/>
				SED_SCRIPT
            else
                # If NIGHTWATCH_ENABLED doesn't exist, add before closing </php> tag
                cat > "$sed_script" <<-'SED_SCRIPT'
					/<\/php>/i\
			<env name="PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD" value="1"/>\
			<env name="PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" value="/usr/bin/chromium-browser"/>
				SED_SCRIPT
            fi

            sed -i -f "$sed_script" phpunit.xml
            rm -f "$sed_script"
            
            printf "${GREEN}✅ Added Browser testsuite to phpunit.xml${NC}\n"
        else
            printf "${GREEN}✅ Browser testsuite already configured in phpunit.xml${NC}\n"
        fi
    fi

    # Configure tests/Pest.php to include Browser directory
    if [ -f tests/Pest.php ]; then
        printf "${GRAY}   Configuring tests/Pest.php...${NC}\n"
        
        # Check if Browser directory is already configured
        if ! grep -q "in('Browser')" tests/Pest.php; then
            # Add Browser configuration after Feature configuration
            # Note: Using -e instead of -f because sed script files don't handle a\ continuation well
            sed -i "/->in('Feature');/a\\
pest()->extend(Tests\\\\TestCase::class)\\
    ->in('Browser');" tests/Pest.php
            
            printf "${GREEN}✅ Added Browser directory to tests/Pest.php${NC}\n"
        else
            printf "${GREEN}✅ Browser directory already configured in tests/Pest.php${NC}\n"
        fi
    fi

    # Create tests/Browser directory and example test (only if it doesn't exist)
    printf "${GRAY}   Creating browser test example...${NC}\n"
    mkdir -p tests/Browser
    if [ ! -f tests/Browser/ExampleTest.php ]; then
        cat > tests/Browser/ExampleTest.php <<-'EOL'
		<?php

		test('example', function () {
		    // Increase timeout for browser operations
		    \Pest\Browser\Playwright\Playwright::setTimeout(30_000); // 30 seconds
		    
		    $page = visit('/');
		    
		    $page->assertSee('Laravel');
		});
		EOL
        printf "${GREEN}✅ Created example browser test at tests/Browser/ExampleTest.php${NC}\n"
    else
        printf "${GREEN}✅ Example browser test already exists at tests/Browser/ExampleTest.php${NC}\n"
    fi

    # Add screenshots directory to .gitignore if not present
    if [ -f .gitignore ]; then
        if ! grep -q "/tests/Browser/Screenshots" .gitignore; then
            echo "/tests/Browser/Screenshots" >> .gitignore
            printf "${GREEN}✅ Added /tests/Browser/Screenshots to .gitignore${NC}\n"
        fi
    fi

    # Create symlink to system Chromium (critical for Alpine compatibility)
    function_setup_chromium_symlink

    # Create and apply Playwright timeout fix script
    printf "${GRAY}   Creating Playwright timeout fix script...${NC}\n"
    if [ ! -f fix-playwright-timeout.php ]; then
        cat > fix-playwright-timeout.php <<-'EOL'
		#!/usr/bin/env php
		<?php

		/**
		 * Fix Playwright server timeout issue in Pest browser plugin.
		 * This script increases the stop timeout from 0.1 to 5.0 seconds
		 * and adds a force-kill fallback to prevent hanging processes.
		 */

		$file = __DIR__ . '/vendor/pestphp/pest-plugin-browser/src/Playwright/Servers/PlaywrightNpmServer.php';

		if (!file_exists($file)) {
		    exit(0); // Silently skip if file doesn't exist
		}

		$content = file_get_contents($file);

		// Check if fix is already applied
		if (strpos($content, 'timeout: 5.0') !== false && strpos($content, '// Force kill if still running after timeout') !== false) {
		    exit(0); // Already fixed
		}

		// First, fix any broken replacements (like ".0," instead of "timeout: 5.0,")
		if (preg_match('/\s+\.0,\s+signal: PHP_OS_FAMILY/', $content)) {
		    // Restore broken file to original state
		    $content = preg_replace(
		        '/\s+\.0,\s+signal: PHP_OS_FAMILY === \'Windows\' \? null : SIGTERM,\s+\);/',
		        '            $this->systemProcess->stop(
		                timeout: 0.1,
		                signal: PHP_OS_FAMILY === \'Windows\' ? null : SIGTERM,
		            );',
		        $content
		    );
		    // Remove any broken force-kill code that was incorrectly added
		    $content = preg_replace('/\s+// Force kill if still running after timeout.*?\}\s*\}/s', '', $content);
		}

		// Now do the proper replacement using a simpler, more reliable approach
		// Find the exact pattern we need to replace
		$oldCode = '            $this->systemProcess->stop(
		                timeout: 0.1,
		                signal: PHP_OS_FAMILY === \'Windows\' ? null : SIGTERM,
		            );
		        }

		        $this->systemProcess = null;';

		$newCode = '            $this->systemProcess->stop(
		                timeout: 5.0,
		                signal: PHP_OS_FAMILY === \'Windows\' ? null : SIGTERM,
		            );
		            
		            // Force kill if still running after timeout
		            if ($this->isRunning()) {
		                $this->systemProcess->stop(
		                    timeout: 0.1,
		                    signal: PHP_OS_FAMILY === \'Windows\' ? null : SIGKILL,
		                );
		            }
		        }

		        $this->systemProcess = null;';

		if (strpos($content, $oldCode) !== false) {
		    $content = str_replace($oldCode, $newCode, $content);
		} else {
		    // Fallback: try with flexible whitespace matching
		    $content = preg_replace(
		        '/\$this->systemProcess->stop\(\s+timeout: 0\.1,/',
		        '$this->systemProcess->stop(
		                timeout: 5.0,',
		        $content
		    );
		    
		    // Add force-kill after the stop() call
		    $content = preg_replace(
		        '/(\$this->systemProcess->stop\(\s+timeout: 5\.0,\s+signal: PHP_OS_FAMILY === \'Windows\' \? null : SIGTERM,\s+\);\s+)(\}\s+\$this->systemProcess = null;)/s',
		        '$1            
		            // Force kill if still running after timeout
		            if ($this->isRunning()) {
		                $this->systemProcess->stop(
		                    timeout: 0.1,
		                    signal: PHP_OS_FAMILY === \'Windows\' ? null : SIGKILL,
		                );
		            }
		        }

		        $2',
		        $content
		    );
		}

		file_put_contents($file, $content);
		EOL
        chmod +x fix-playwright-timeout.php
        printf "${GREEN}✅ Created fix-playwright-timeout.php${NC}\n"
    else
        printf "${GREEN}✅ fix-playwright-timeout.php already exists${NC}\n"
    fi

    # Apply the timeout fix immediately
    printf "${GRAY}   Applying Playwright timeout fix...${NC}\n"
    php fix-playwright-timeout.php 2>/dev/null && {
        printf "${GREEN}✅ Applied Playwright timeout fix${NC}\n"
    } || {
        printf "${GRAY}   (Fix will be applied after composer install)${NC}\n"
    }

    # Add post-update-cmd to composer.json to automatically recreate symlink and apply timeout fix after composer update
    if [ -f composer.json ]; then
        printf "${GRAY}   Configuring composer.json post-update-cmd...${NC}\n"
        
        # Check if post-update-cmd already exists
        if grep -q '"post-update-cmd"' composer.json; then
            # Check if our fixes are already in the post-update-cmd
            has_symlink_fix=false
            has_timeout_fix=false
            if grep -q 'function_setup_chromium_symlink' composer.json; then
                has_symlink_fix=true
            fi
            if grep -q 'fix-playwright-timeout.php' composer.json; then
                has_timeout_fix=true
            fi

            if [ "$has_symlink_fix" = true ] && [ "$has_timeout_fix" = true ]; then
                printf "${GREEN}✅ post-update-cmd already configured for browser testing${NC}\n"
            else
                # Add our commands to existing post-update-cmd array
                # Use PHP to safely modify JSON
                php_script=$(mktemp)
                cat > "$php_script" <<-'PHP_SCRIPT'
					<?php
					$json = json_decode(file_get_contents('composer.json'), true);
					if (!isset($json['scripts']['post-update-cmd'])) {
					    $json['scripts']['post-update-cmd'] = [];
					}
					if (!is_array($json['scripts']['post-update-cmd'])) {
					    $json['scripts']['post-update-cmd'] = [$json['scripts']['post-update-cmd']];
					}
					
					$symlink_cmd = 'bash -c "if [ -f laravel-app.sh ]; then source laravel-app.sh && function_setup_chromium_symlink; fi"';
					$timeout_cmd = '@php fix-playwright-timeout.php';
					
					if (!in_array($symlink_cmd, $json['scripts']['post-update-cmd'])) {
					    $json['scripts']['post-update-cmd'][] = $symlink_cmd;
					}
					if (!in_array($timeout_cmd, $json['scripts']['post-update-cmd'])) {
					    $json['scripts']['post-update-cmd'][] = $timeout_cmd;
					}
					
					file_put_contents('composer.json', json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
					echo 'Updated post-update-cmd';
				PHP_SCRIPT

                php "$php_script" 2>/dev/null && {
                    printf "${GREEN}✅ Added browser testing fixes to existing post-update-cmd${NC}\n"
                } || {
                    printf "${YELLOW}⚠️  Could not automatically add to post-update-cmd (may need manual configuration)${NC}\n"
                }
                rm -f "$php_script"
            fi
        else
            # Add new post-update-cmd section
            php_script=$(mktemp)
            cat > "$php_script" <<-'PHP_SCRIPT'
				<?php
				$json = json_decode(file_get_contents('composer.json'), true);
				if (!isset($json['scripts'])) {
				    $json['scripts'] = [];
				}
				$json['scripts']['post-update-cmd'] = [
				    '@php artisan config:clear --ansi',
				    'bash -c "if [ -f laravel-app.sh ]; then source laravel-app.sh && function_setup_chromium_symlink; fi"',
				    '@php fix-playwright-timeout.php'
				];
				file_put_contents('composer.json', json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
			PHP_SCRIPT

            php "$php_script" 2>/dev/null && {
                printf "${GREEN}✅ Added post-update-cmd to composer.json${NC}\n"
            } || {
                printf "${YELLOW}⚠️  Could not automatically add post-update-cmd (may need manual configuration)${NC}\n"
            }
            rm -f "$php_script"
        fi
    fi

    printf "\n${GREEN}✅ Browser testing setup complete!${NC}\n"
    printf "${GRAY}   Run tests with: ${WHITE}php artisan test${NC}\n"
    printf "${GRAY}   Or browser tests only: ${WHITE}php artisan test --testsuite=Browser${NC}\n"
    printf "${GRAY}   Symlink and timeout fix will be automatically reapplied after 'composer update'${NC}\n"
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

function_install_tailwind() {
    printf "${GRAY}✨ ${WHITE}Installing Tailwind CSS and configs...${NC}\n"

    # Install Tailwind-related packages and update node_modules
    npm install -D tailwindcss postcss autoprefixer @tailwindcss/vite

    # Create tailwind.config.js if missing
    if [ ! -f tailwind.config.js ]; then
        cat > tailwind.config.js <<-EOF
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
        cat > postcss.config.js <<-EOF
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
    for FILE_VITE in "$FILE_VITE_BASE.js" "$FILE_VITE_BASE.ts"; do
        if [ -f "$FILE_VITE" ]; then
            if ! grep -q 'tailwindcss' "$FILE_VITE"; then
                # Insert import at the top after other imports
                sed -i '1i import tailwindcss from "@tailwindcss/vite";' "$FILE_VITE"

                # Add tailwindcss() to plugins array (naive approach)
                sed -i '/plugins: \[/a \        tailwindcss(),' "$FILE_VITE"

                printf "Added Tailwind plugin to '$FILE_VITE'\n"
            fi
        fi
    done

    printf "${GREEN}✅ ${WHITE}Tailwind installed and configured!${NC}\n"
}

function_remove_tailwind() {
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
    for FILE_VITE in "$FILE_VITE_BASE.js" "$FILE_VITE_BASE.ts"; do
        if [ -f "$FILE_VITE" ]; then
            if grep -q 'tailwindcss' "$FILE_VITE"; then
                sed -i '/import.*tailwindcss.*/d' "$FILE_VITE"
                sed -i '/tailwindcss(),/d' "$FILE_VITE"
            fi
        fi
    done

    # Remove any leftover Tailwind node_modules folders
    rm -rf node_modules/tailwindcss node_modules/@tailwindcss

    # Prune unused packages from node_modules and update package-lock.json
    npm prune --omit=dev
    npm install

    printf "${GREEN}✅ ${WHITE}Tailwind removed and dependencies updated.${NC}\n"
}

function_setup_chromium_symlink() {
    printf "${GRAY}   Setting up system Chromium symlink...${NC}\n"
    SYSTEM_CHROMIUM="/usr/bin/chromium-browser"
    
    if [ ! -f "$SYSTEM_CHROMIUM" ]; then
        printf "${YELLOW}⚠️  System Chromium not found at $SYSTEM_CHROMIUM. Install with: apk add chromium${NC}\n"
        return 1
    fi

    # Find Playwright cache directory
    PLAYWRIGHT_CACHE_DIR=""
    if [ -d "$PWD/.cache/ms-playwright" ]; then
        PLAYWRIGHT_CACHE_DIR="$PWD/.cache/ms-playwright"
    elif [ -d "/var/www/html/.cache/ms-playwright" ]; then
        PLAYWRIGHT_CACHE_DIR="/var/www/html/.cache/ms-playwright"
    elif [ -d "$HOME/.cache/ms-playwright" ]; then
        PLAYWRIGHT_CACHE_DIR="$HOME/.cache/ms-playwright"
    fi

    if [ -z "$PLAYWRIGHT_CACHE_DIR" ] || [ ! -d "$PLAYWRIGHT_CACHE_DIR" ]; then
        printf "${YELLOW}⚠️  Playwright cache directory not found. Run 'npx playwright install chromium' first.${NC}\n"
        return 1
    fi

    # Find Chromium version directory (auto-detect, gets the latest/most recent)
    # Look for chromium_headless_shell directories and find chrome-linux subdirectory
    CHROMIUM_BASE_DIR=$(find "$PLAYWRIGHT_CACHE_DIR" -type d -name "chromium_headless_shell-*" 2>/dev/null | head -1)
    if [ -n "$CHROMIUM_BASE_DIR" ] && [ -d "$CHROMIUM_BASE_DIR/chrome-linux" ]; then
        CHROMIUM_DIR="$CHROMIUM_BASE_DIR/chrome-linux"
    else
        CHROMIUM_DIR=""
    fi

    if [ -z "$CHROMIUM_DIR" ] || [ ! -d "$CHROMIUM_DIR" ]; then
        printf "${YELLOW}⚠️  Playwright Chromium directory not found. Run 'npx playwright install chromium' first.${NC}\n"
        return 1
    fi

    # Check if symlink already exists and is correct
    if [ -L "$CHROMIUM_DIR/headless_shell" ]; then
        CURRENT_TARGET=$(readlink -f "$CHROMIUM_DIR/headless_shell" 2>/dev/null || readlink "$CHROMIUM_DIR/headless_shell" 2>/dev/null)
        if [ "$CURRENT_TARGET" = "$SYSTEM_CHROMIUM" ]; then
            printf "${GREEN}✅ Symlink already exists and is correct: $CHROMIUM_DIR/headless_shell -> $SYSTEM_CHROMIUM${NC}\n"
            return 0
        else
            printf "${GRAY}   Existing symlink points to different target, updating...${NC}\n"
            rm "$CHROMIUM_DIR/headless_shell" 2>/dev/null || true
        fi
    fi

    # Backup original if it exists and is not a symlink
    if [ -f "$CHROMIUM_DIR/headless_shell" ] && [ ! -L "$CHROMIUM_DIR/headless_shell" ]; then
        printf "${GRAY}   Backing up original headless_shell...${NC}\n"
        mv "$CHROMIUM_DIR/headless_shell" "$CHROMIUM_DIR/headless_shell.backup" 2>/dev/null || true
    fi

    # Create symlink
    if ln -sf "$SYSTEM_CHROMIUM" "$CHROMIUM_DIR/headless_shell" 2>/dev/null; then
        printf "${GREEN}✅ Created symlink: $CHROMIUM_DIR/headless_shell -> $SYSTEM_CHROMIUM${NC}\n"
        return 0
    else
        printf "${YELLOW}⚠️  Could not create symlink (may need to run manually)${NC}\n"
        return 1
    fi
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
    
    # Clear any previous failed attempts
    rm -rf "$TEMP_DIR" vendor composer.lock composer.json
    
    # Clear composer cache to avoid corrupted downloads
    composer clear-cache
    
    # Install Laravel installer
    printf "${ORANGE}📦 ${WHITE}Installing Laravel installer...${NC}\n"
    composer require laravel/installer --no-interaction
    
    # Run Laravel installer with increased memory and error handling
    max_attempts=3
    attempt=1
    installation_successful=false
    
    while [ $attempt -le $max_attempts ]; do
        printf "\n${ORANGE}📦 ${WHITE}Installation attempt $attempt of $max_attempts...${NC}\n"
        
        if COMPOSER_MEMORY_LIMIT=-1 vendor/bin/laravel new --database=sqlite --npm "$TEMP_DIR"; then
            printf "${GREEN}✅ Installation successful!${NC}\n"
            installation_successful=true
            break
        else
            printf "${RED}❌ Installation attempt $attempt failed${NC}\n"
            
            if [ $attempt -lt $max_attempts ]; then
                printf "${YELLOW}⚠️  Cleaning up and retrying...${NC}\n"
                
                # Cleanup
                rm -rf "$TEMP_DIR"
                composer clear-cache
                sleep 3
                
                printf "${ORANGE}📦 ${WHITE}Re-installing Laravel installer...${NC}\n"
                composer require laravel/installer --no-interaction
            else
                printf "${RED}❌ Laravel installation failed after $max_attempts attempts${NC}\n"
                printf "${YELLOW}💡 Troubleshooting tips:${NC}\n"
                printf "${YELLOW}   - Check disk space: df -h${NC}\n"
                printf "${YELLOW}   - Check available inodes: df -i${NC}\n"
                printf "${YELLOW}   - Check Docker container resources${NC}\n"
                printf "${YELLOW}   - Try restarting the container: docker restart app${NC}\n"
                exit 1
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    if [ "$installation_successful" = false ]; then
        printf "${RED}❌ Failed to install Laravel${NC}\n"
        exit 1
    fi

    printf "\n${ORANGE}📦 ${WHITE}Moving project files...${NC}\n"
    # This method of moving the application should avoid any file limit issues
    rm -rf vendor composer*
    mv "$TEMP_DIR"/vendor ./
    rm -rf "$TEMP_DIR"/.git*
    find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -exec mv -t . {} +
    rm -rf "$TEMP_DIR"
    printf "${GREEN}✅ Project moved!${NC}\n"

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
    function_install_browser_testing

    echo ""
    printf "\n${GREEN}✅ Laravel scaffolding complete.${NC}\n"
else
    [ ! -d node_modules ] && function_install_npm
    [ ! -d vendor ] && function_install_composer
    function_configure_database
    function_configure_vite
    function_configure_gitignore
    function_install_browser_testing

    printf "\n${GREEN}✅ Laravel application already exists.${NC}\n"
fi
