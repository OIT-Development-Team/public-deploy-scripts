#!/bin/sh
#Version 1.8

# Set default values for boolean options
provision_app=false
FORWARD_ARGS=""

# Parse command-line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --new)
      provision_app=true
      ;;
    --livewire|--no-livewire|--pv|--tailwind|--no-tailwind|--ua-template|--no-ua-template|--windows|--no-windows)
      FORWARD_ARGS="$FORWARD_ARGS $1"
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

#Pull down github action file
if [ ! -f .github/workflows/build.yaml ]; then
       curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/tags/stable/build.yaml --create-dirs -o .github/workflows/build.yaml
fi

#Pull down git pre-commit hook file
if [ ! -f .git/hooks/pre-commit ]; then
       curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/tags/stable/laravel-hooks/pre-commit --create-dirs -o .git/hooks/pre-commit
	   chmod +x .git/hooks/pre-commit
fi

#Pull down docker-compose.yaml file
if [ ! -f docker-compose.yaml ]; then
       curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/tags/stable/docker-compose.yaml --create-dirs -o docker-compose.yaml
fi

#Pull down deploy-plan.json file
if [ ! -f deploy-plan.json ]; then
       curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/tags/stable/deploy-plan.json --create-dirs -o deploy-plan.json
fi

# Pull and run add-pv.sh if the --pv flag is used.
#if echo "$FORWARD_ARGS" | grep -qw -- --pv; then
       curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/tags/stable/add-pv.sh --create-dirs -o add-pv.sh
       chmod +x add-pv.sh
       ./add-pv.sh
	   rm add-pv.sh
#fi

#give developers a script to create a new laravel project if a laravel app is not detected
if [ ! -d app ]; then
       if [ ! -f new-laravel-app.sh ]; then
              curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/tags/stable/new-laravel-app.sh --create-dirs -o new-laravel-app.sh
              chmod +x new-laravel-app.sh
       fi
fi


curl -X POST -d @deploy-plan.json --header "Content-Type: application/json" -H "AUTH: $AUTH" https://build-dockerfile-api.oitapps.ua.edu/api/docker/build-dev > Dockerfile.dev

#Build and run container
docker stop app
docker rm app

# Check for Windows by detecting 'OS' environment variable in Bash
if [ "$OS" = "Windows_NT" ]; then
    # Windows environment (Bash)
	if command -v docker-compose >/dev/null 2>&1; then
        docker-compose up -d --build
    else
        docker compose up -d --build
    fi
else
    # Unix-like environment (Linux, macOS)
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose up -d --build
    else
        docker compose up -d --build
    fi
fi


if $provision_app; then
    echo "Creating New Laravel Application!"
    eval docker exec -it app ./new-laravel-app.sh $FORWARD_ARGS
    rm new-laravel-app.sh
fi

# run npm run dev in the bg if theres an app folder and package-lock.json (npm install has been ran)
echo "Checking to see if we can npm run dev in background..."
if [ -d app ]; then
    echo "Running npm run dev in the background..."
    docker exec -d app npm run dev
fi