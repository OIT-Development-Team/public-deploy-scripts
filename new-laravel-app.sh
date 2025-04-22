#!/bin/sh

# Set default values for boolean options
livewire=true
tailwind=true

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --livewire)
      livewire=true
      shift
    ;;
    --no-livewire)
      livewire=false
      shift
    ;;
    --tailwind)
      tailwind=true
      shift
    ;;
    --no-tailwind)
      tailwind=false
      shift
    ;;
    *)
      echo "Unknown option: $1"
      exit 1
    ;;
  esac
done

# Check if the 'app' directory exists
if [ ! -d app ]; then
    export COMPOSER_PROCESS_TIMEOUT=600

    # Install with or without Tailwind
    if $tailwind; then
		echo "Creating Laravel project with Tailwind..." && \
        composer create-project laravel/laravel new-app && \
        echo "✅ Laravel project created with Tailwind."
    else
		echo "Creating Laravel project without Tailwind..." && \
        composer create-project laravel/laravel new-app && \
        rm -f new-app/tailwind.config.js new-app/postcss.config.js && \
        sed -i '/@tailwind/d' new-app/resources/css/app.css && \
        sed -i "/@import 'tailwindcss';/d" new-app/resources/css/app.css && \
        sed -i '/^@source /d' new-app/resources/css/app.css && \
        sed -i '/^@theme {/,/^}/d' new-app/resources/css/app.css && \
        echo ":root {\n    --font-sans: 'Instrument Sans', ui-sans-serif, system-ui, sans-serif, 'Apple Color Emoji', 'Segoe UI Emoji',\n        'Segoe UI Symbol', 'Noto Color Emoji';\n}\n" > new-app/resources/css/app.css && \
        sed -i '/@tailwindcss\/vite/d' new-app/vite.config.js && \
        sed -i '/"tailwindcss":/d' new-app/package.json && \
        sed -i '/"postcss":/d' new-app/package.json && \
        sed -i '/"autoprefixer":/d' new-app/package.json && \
        sed -i '/"@tailwindcss\/vite":/d' new-app/package.json && \
        echo "✅ Laravel project created without Tailwind."
    fi

    mv new-app/* .
    cp new-app/.* .
    rm -rf new-app

    # Ensure the trustProxies is configured in bootstrap/app.php
    APP_FILE="bootstrap/app.php"

    if [ -f "$APP_FILE" ]; then
        echo "Setting trusted proxies..."

        # Define the new trustProxies configuration with proper indentation
        NEW_TRUST_PROXIES="\t\t\$middleware->trustProxies(at: [\n\t\t\t\"10.42.0.0/16\",\n\t\t\t\"10.8.0.0/16\",\n\t\t\t\"10.1.0.0/16\"\n\t\t]);"

        # Remove the existing trustProxies configuration if it exists
        if grep -q '\$middleware->trustProxies(at:' "$APP_FILE"; then
            sed -i "/\$middleware->trustProxies(at:/,/]);/d" "$APP_FILE"
            echo "Removed existing trustProxies configuration from bootstrap/app.php."
        fi

        # Add the new trustProxies configuration
        sed -i "/->withMiddleware(function (Middleware \$middleware) {/a\\
$NEW_TRUST_PROXIES" "$APP_FILE"
        echo "Added trustProxies configuration to bootstrap/app.php."
    else
        echo "App configuration file bootstrap/app.php not found!"
    fi

    # Ensure the logging configuration is updated for both new and existing projects
    LOGGING_FILE="config/logging.php"

    if [ -f "$LOGGING_FILE" ]; then
        echo "Updating logging configuration..."

        # Update 'default' => 'stack'
        sed -i "s/'default' =>.*/'default' => 'stack',/" "$LOGGING_FILE"

        # Remove existing 'stack' block completely, without removing surrounding lines
        sed -i "/'stack' => \[/,/^\s*],\?/c\\
        'stack' => [\\
            'driver' => 'stack',\\
            'channels' => ['daily', 'stderr'],\\
            'ignore_exceptions' => false,\\
        ]," "$LOGGING_FILE"

        echo "Logging configuration updated."
    else
        echo "Logging configuration file not found!"
    fi

    # Ensure the cache configuration is updated for both new and existing projects
    CACHING_FILE="config/cache.php"

    if [ -f "$CACHING_FILE" ]; then
        echo "Updating caching configuration..."

        # Update 'default' => 'file'
        sed -i "s/'default' =>.*/'default' => 'file',/" "$CACHING_FILE"

        echo "Caching set to file"
    else
        echo "Caching configuration file not found!"
    fi

    # Ensure the session configuration is updated for both new and existing projects
    SESSION_FILE="config/session.php"

    if [ -f "$SESSION_FILE" ]; then
        echo "Updating session configuration..."

        # Update 'driver' => 'file'
        sed -i "s/'driver' =>.*/'driver' => 'file',/" "$SESSION_FILE"

        echo "Session driver set to file"
    else
        echo "Session configuration file not found!"
    fi

    # Additional configuration based on deploy-plan.json

    # Extract the first database in the "databases" array from deploy-plan.json
    DB_CONNECTION=$(php -r "echo json_decode(file_get_contents('deploy-plan.json'), true)['image']['databases'][0];")
    echo "Extracted DB_CONNECTION: $DB_CONNECTION"

    # Set default database connection in config/database.php
    if [ -f "config/database.php" ]; then
        # Use sed to update the 'default' setting for the database connection
        sed -i "s/'default' => env('DB_CONNECTION', '[^']*')/'default' => env('DB_CONNECTION', '$DB_CONNECTION')/" "config/database.php"
        echo "Default database set to $DB_CONNECTION in config/database.php."

        # Update or create DB_CONNECTION in .env file
        if grep -q '^DB_CONNECTION=' ".env"; then
            sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=$DB_CONNECTION/" ".env"
        else
            echo "DB_CONNECTION=$DB_CONNECTION" >> ".env"
        fi
        echo "DB_CONNECTION set to $DB_CONNECTION in .env file."

        # Check if "oracle" exists in the databases array and install its driver if it does
        if php -r "echo json_encode(json_decode(file_get_contents('deploy-plan.json'), true)['image']['databases']);" | grep -q '"oracle"'; then
            echo "Installing Oracle driver."

            # Install yajra/laravel-oci8 package
            composer require yajra/laravel-oci8
        fi
    else
        echo "Database configuration file not found!"
    fi

    # Update README.md with new contents
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

    echo "Updated README.md with new contents."

    #-------------------------------------------------------------------------------------

    # Update the vite.config.js file
    sed -i '/^export default defineConfig({/a\
        server: {\
            host: true,\
        },' vite.config.js
    echo "Updated vite config"

    #-------------------------------------------------------------------------------------

    # Run npm install
    echo "Running npm install..."
    npm install

    #-------------------------------------------------------------------------------------

    # Install Livewire
    if $livewire; then
        echo "Installing Livewire..."
        composer require livewire/livewire
        echo "Livewire Installed"
    fi

    #-------------------------------------------------------------------------------------

    # Install Tailwind
    #if $tailwind; then
    #    echo "Installing Tailwind..."
    #    curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/tags/pint/app.css -o resources/css/app.css
    #    echo "Installed Tailwind"
    #fi

    #-------------------------------------------------------------------------------------

    # Install base template
    wget -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/NavLinks.php && \
    wget -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/nav-links.blade.php && \
    wget -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/VerticalLayout.php && \
    wget -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/vertical-layout.blade.php && \
    wget -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/Dropdown.php && \
    wget -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/dropdown.blade.php
    wget -nc -P app/View/Components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/Components/ThemeSelector.php && \
    wget -nc -P resources/views/components https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/component-views/theme-selector.blade.php
    wget -nc -P public/img https://raw.githubusercontent.com/OIT-Development-Team/ui-components-public/refs/heads/main/img/nameplate.png


else
    echo "You already have a Laravel project!"
fi

