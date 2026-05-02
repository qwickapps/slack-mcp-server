#!/bin/bash
set -e

# Build Workspace Package Script
# Builds workspace packages and creates standalone deployment package
#
# Usage:
#   ./build-workspace-package.sh --product <product-path> --packages <pkg1,pkg2,...>
#
# Example:
#   ./build-workspace-package.sh \
#     --product products/qwickai/compute-service \
#     --packages logging,schema,react-framework,server,compute-orchestrator

# Save workspace root directory
WORKSPACE_ROOT="$(pwd)"

# Parse arguments
PRODUCT_PATH=""
WORKSPACE_PACKAGES=""
OUTPUT_DIR="deploy-package"

while [[ $# -gt 0 ]]; do
  case $1 in
    --product)
      PRODUCT_PATH="$2"
      shift 2
      ;;
    --packages)
      WORKSPACE_PACKAGES="$2"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$PRODUCT_PATH" ]; then
  echo "Error: --product is required"
  exit 1
fi

if [ -z "$WORKSPACE_PACKAGES" ]; then
  echo "Error: --packages is required"
  exit 1
fi

echo "========================================="
echo "Build Workspace Package"
echo "========================================="
echo "Product: $PRODUCT_PATH"
echo "Packages: $WORKSPACE_PACKAGES"
echo "Output: $OUTPUT_DIR"
echo "========================================="

# Validate workspace dependencies before building
echo ""
echo "Validating workspace dependencies..."
if ! node "$WORKSPACE_ROOT/.github/scripts/validate-workspace-deps.js" 2>/dev/null; then
  echo ""
  echo "❌ ERROR: Invalid workspace dependencies detected!"
  echo "   Unpublished @qwickapps packages must use 'workspace:*' protocol."
  echo ""
  echo "   To fix automatically, run:"
  echo "   node .github/scripts/fix-workspace-deps.js"
  echo ""
  exit 1
fi
echo "✅ Workspace dependencies validated"

# Clean old builds
echo ""
echo "Cleaning old builds..."
IFS=',' read -ra PKG_ARRAY <<< "$WORKSPACE_PACKAGES"
for pkg in "${PKG_ARRAY[@]}"; do
  pkg=$(echo "$pkg" | xargs)  # trim whitespace

  # Determine package path - try with qwickapps- prefix first, then without
  if [ "$pkg" = "compute-orchestrator" ]; then
    PKG_PATH="packages/$pkg"
  elif [ -d "packages/qwickapps-$pkg" ]; then
    PKG_PATH="packages/qwickapps-$pkg"
  elif [ -d "packages/$pkg" ]; then
    PKG_PATH="packages/$pkg"
  else
    PKG_PATH="packages/qwickapps-$pkg"  # fallback
  fi

  if [ -d "$PKG_PATH/dist" ]; then
    rm -rf "$PKG_PATH/dist"
    echo "  Cleaned $PKG_PATH/dist"
  fi
done

# Clean .tsbuildinfo files
find packages -name ".tsbuildinfo" -delete 2>/dev/null || true

# Build workspace packages
echo ""
echo "Building workspace packages..."
for pkg in "${PKG_ARRAY[@]}"; do
  pkg=$(echo "$pkg" | xargs)

  # Map to @qwickapps scope
  if [ "$pkg" = "compute-orchestrator" ]; then
    FILTER_NAME="@qwickapps/$pkg"
  else
    FILTER_NAME="@qwickapps/$pkg"
  fi

  echo "  Building $FILTER_NAME..."
  NODE_OPTIONS="--max-old-space-size=4096" pnpm --filter "$FILTER_NAME" build
done

# Build the product service
echo ""
echo "Building product service..."
cd "$PRODUCT_PATH"

# Clear Next.js cache if it exists (forces TypeScript to re-check types)
if [ -d ".next" ]; then
  rm -rf .next
  echo "  Cleared .next cache"
fi

pnpm run build

# Navigate back to workspace root
cd - > /dev/null

# Create standalone deployment package
echo ""
echo "Creating standalone deployment package..."
cd "$PRODUCT_PATH"

# Clean output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/node_modules/@qwickapps"

# Copy built workspace packages (dist + package.json only, no source or node_modules)
echo "  Copying workspace packages..."
for pkg in "${PKG_ARRAY[@]}"; do
  pkg=$(echo "$pkg" | xargs)

  # Determine source path - try with qwickapps- prefix first, then without
  if [ "$pkg" = "compute-orchestrator" ]; then
    SRC_PATH="../../packages/$pkg"
  elif [ -d "../../packages/qwickapps-$pkg" ]; then
    SRC_PATH="../../packages/qwickapps-$pkg"
  elif [ -d "../../packages/$pkg" ]; then
    SRC_PATH="../../packages/$pkg"
  else
    SRC_PATH="../../packages/qwickapps-$pkg"  # fallback for error message
  fi

  if [ -d "$SRC_PATH" ]; then
    DEST_PATH="$OUTPUT_DIR/node_modules/@qwickapps/$pkg"
    mkdir -p "$DEST_PATH"

    # Copy only essential files for production
    # Copy all build output directories (dist, dist-ui, dist-ui-lib, etc.)
    FOUND_BUILD_DIR=false
    for build_dir in dist dist-ui dist-ui-lib; do
      if [ -d "$SRC_PATH/$build_dir" ]; then
        cp -r "$SRC_PATH/$build_dir" "$DEST_PATH/"
        echo "    Copied $pkg/$build_dir"
        FOUND_BUILD_DIR=true
      fi
    done

    if [ "$FOUND_BUILD_DIR" = false ]; then
      echo "    Warning: No build directories found in $SRC_PATH"
    fi

    if [ -f "$SRC_PATH/package.json" ]; then
      cp "$SRC_PATH/package.json" "$DEST_PATH/"
      echo "    Copied $pkg/package.json"
    else
      echo "    Warning: $SRC_PATH/package.json not found"
    fi

    # Copy README if exists (optional, for documentation)
    if [ -f "$SRC_PATH/README.md" ]; then
      cp "$SRC_PATH/README.md" "$DEST_PATH/"
    fi
  else
    echo "    Warning: $SRC_PATH not found"
  fi
done

# Verify no symlinks in workspace packages
echo "  Verifying workspace packages..."
SYMLINK_COUNT=$(find "$OUTPUT_DIR/node_modules/@qwickapps" -type l 2>/dev/null | wc -l)
if [ "$SYMLINK_COUNT" -gt 0 ]; then
  echo "  Error: Found $SYMLINK_COUNT symlinks in workspace packages!"
  find "$OUTPUT_DIR/node_modules/@qwickapps" -type l
  exit 1
fi
echo "    ✓ No symlinks found in workspace packages"

# Remove workspace dependencies from copied workspace packages
# This prevents npm install from encountering workspace:* protocol
echo "  Removing workspace dependencies from copied workspace packages..."
for pkg in "${PKG_ARRAY[@]}"; do
  pkg=$(echo "$pkg" | xargs)
  PKG_JSON="$OUTPUT_DIR/node_modules/@qwickapps/$pkg/package.json"

  if [ -f "$PKG_JSON" ]; then
    node -e "
      const fs = require('fs');
      const pkg = JSON.parse(fs.readFileSync('$PKG_JSON', 'utf8'));

      // Remove workspace:* protocol dependencies
      if (pkg.dependencies) {
        Object.keys(pkg.dependencies).forEach(dep => {
          if (pkg.dependencies[dep].startsWith('workspace:')) {
            delete pkg.dependencies[dep];
          }
        });
      }
      if (pkg.devDependencies) {
        Object.keys(pkg.devDependencies).forEach(dep => {
          if (pkg.devDependencies[dep].startsWith('workspace:')) {
            delete pkg.devDependencies[dep];
          }
        });
      }
      if (pkg.optionalDependencies) {
        Object.keys(pkg.optionalDependencies).forEach(dep => {
          if (pkg.optionalDependencies[dep].startsWith('workspace:')) {
            delete pkg.optionalDependencies[dep];
          }
        });
      }

      fs.writeFileSync('$PKG_JSON', JSON.stringify(pkg, null, 2));
    "
    echo "    ✓ Cleaned $pkg/package.json"
  fi
done

# Copy package.json
echo "  Copying package.json..."
cp package.json "$OUTPUT_DIR/"

# Remove workspace dependencies from package.json
echo "  Removing workspace dependencies from package.json..."
cd "$OUTPUT_DIR"

# Use Node.js to properly remove workspace dependencies
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));

// Remove ALL workspace:* dependencies (not just the ones in packages list)
if (pkg.dependencies) {
  Object.keys(pkg.dependencies).forEach(dep => {
    if (pkg.dependencies[dep].startsWith('workspace:')) {
      delete pkg.dependencies[dep];
    }
  });
}

if (pkg.devDependencies) {
  Object.keys(pkg.devDependencies).forEach(dep => {
    if (pkg.devDependencies[dep].startsWith('workspace:')) {
      delete pkg.devDependencies[dep];
    }
  });
}

if (pkg.optionalDependencies) {
  Object.keys(pkg.optionalDependencies).forEach(dep => {
    if (pkg.optionalDependencies[dep].startsWith('workspace:')) {
      delete pkg.optionalDependencies[dep];
    }
  });
}

fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
"

# Remove lock files that might interfere with npm install
echo "  Removing lock files..."
rm -f package-lock.json pnpm-lock.yaml yarn.lock

# Debug: Show package.json dependencies to verify workspace:* removal
echo "  Verifying workspace dependencies removed..."
node -e "
const pkg = JSON.parse(require('fs').readFileSync('package.json', 'utf8'));
const workspaceDeps = [];
if (pkg.dependencies) {
  Object.keys(pkg.dependencies).forEach(dep => {
    if (pkg.dependencies[dep].startsWith('workspace:')) {
      workspaceDeps.push(\`\${dep}: \${pkg.dependencies[dep]}\`);
    }
  });
}
if (pkg.devDependencies) {
  Object.keys(pkg.devDependencies).forEach(dep => {
    if (pkg.devDependencies[dep].startsWith('workspace:')) {
      workspaceDeps.push(\`\${dep}: \${pkg.devDependencies[dep]}\`);
    }
  });
}
if (workspaceDeps.length > 0) {
  console.log('    ERROR: Found workspace dependencies:');
  workspaceDeps.forEach(dep => console.log(\`    - \${dep}\`));
  process.exit(1);
} else {
  console.log('    ✓ No workspace dependencies found');
}
"

# Install production dependencies (will prune node_modules/@qwickapps/)
echo "  Installing production dependencies..."
npm install --legacy-peer-deps

if [ $? -ne 0 ]; then
  echo "Error: npm install failed!"
  exit 1
fi

# Debug: Verify Next.js was installed (only if project depends on it)
USES_NEXTJS=$(node -e "const pkg = require('./package.json'); console.log(pkg.dependencies?.next ? 'true' : 'false');")
if [ "$USES_NEXTJS" = "true" ]; then
  echo "  Verifying Next.js installation..."
  if [ -d "node_modules/next" ]; then
    echo "    ✓ Next.js installed at node_modules/next"
    if [ -f "node_modules/next/dist/bin/next" ]; then
      echo "    ✓ Next.js binary found at node_modules/next/dist/bin/next"
    else
      echo "    ERROR: Next.js binary NOT found at node_modules/next/dist/bin/next"
      ls -la node_modules/next/dist/bin/ || echo "    ERROR: node_modules/next/dist/bin/ does not exist"
      exit 1
    fi
  else
    echo "    ERROR: Next.js NOT installed in node_modules/"
    echo "    Checking package.json dependencies..."
    node -e "const pkg = require('./package.json'); console.log('next:', pkg.dependencies?.next || 'NOT FOUND');"
    exit 1
  fi
fi

# Re-copy workspace packages (npm install pruned them)
echo "  Re-copying workspace packages after npm install..."
# Return to workspace root
cd "$WORKSPACE_ROOT"

for pkg in "${PKG_ARRAY[@]}"; do
  pkg=$(echo "$pkg" | xargs)

  # Determine package path - try with qwickapps- prefix first, then without
  if [ "$pkg" = "compute-orchestrator" ]; then
    SRC_PATH="packages/$pkg"
  elif [ -d "packages/qwickapps-$pkg" ]; then
    SRC_PATH="packages/qwickapps-$pkg"
  elif [ -d "packages/$pkg" ]; then
    SRC_PATH="packages/$pkg"
  else
    SRC_PATH="packages/qwickapps-$pkg"  # fallback for error message
  fi

  if [ -d "$SRC_PATH" ]; then
    # Navigate into OUTPUT_DIR for copy operations
    cd "$WORKSPACE_ROOT/$PRODUCT_PATH/$OUTPUT_DIR"
    DEST_PATH="node_modules/@qwickapps/$pkg"

    # Remove existing if it's a symlink or file, then create directory
    if [ -e "$DEST_PATH" ] || [ -L "$DEST_PATH" ]; then
      rm -rf "$DEST_PATH"
    fi
    mkdir -p "$DEST_PATH"

    # Go back to root for source path resolution
    cd "$WORKSPACE_ROOT"

    # Copy only essential files for production
    # Copy all build output directories (dist, dist-ui, dist-ui-lib, etc.)
    for build_dir in dist dist-ui dist-ui-lib; do
      if [ -d "$SRC_PATH/$build_dir" ]; then
        cp -r "$SRC_PATH/$build_dir" "$WORKSPACE_ROOT/$PRODUCT_PATH/$OUTPUT_DIR/$DEST_PATH/"
        echo "    Copied $pkg/$build_dir"
      fi
    done

    if [ -f "$SRC_PATH/package.json" ]; then
      cp "$SRC_PATH/package.json" "$WORKSPACE_ROOT/$PRODUCT_PATH/$OUTPUT_DIR/$DEST_PATH/"
      echo "    Copied $pkg/package.json"
    fi

    if [ -f "$SRC_PATH/README.md" ]; then
      cp "$SRC_PATH/README.md" "$WORKSPACE_ROOT/$PRODUCT_PATH/$OUTPUT_DIR/$DEST_PATH/"
    fi
  else
    echo "    Warning: $SRC_PATH not found"
  fi
done

# Return to OUTPUT_DIR for verification
cd "$WORKSPACE_ROOT/$PRODUCT_PATH/$OUTPUT_DIR"

if [ $? -ne 0 ]; then
  echo "Error: npm install failed!"
  exit 1
fi

# Verify workspace packages are still real directories (not symlinks)
echo "  Re-verifying workspace packages after npm install..."
for pkg in "${PKG_ARRAY[@]}"; do
  pkg=$(echo "$pkg" | xargs)
  PKG_DIR="node_modules/@qwickapps/$pkg"

  if [ -L "$PKG_DIR" ]; then
    echo "  Error: $pkg is a symlink after npm install!"
    ls -la "node_modules/@qwickapps/"
    exit 1
  elif [ ! -d "$PKG_DIR" ]; then
    echo "  Error: $pkg directory missing after npm install!"
    ls -la "node_modules/@qwickapps/"
    exit 1
  fi
done
echo "    ✓ All workspace packages are real directories"

# Install dependencies for each workspace package
echo "  Installing workspace package dependencies..."
for pkg in "${PKG_ARRAY[@]}"; do
  pkg=$(echo "$pkg" | xargs)
  PKG_DIR="node_modules/@qwickapps/$pkg"

  if [ -f "$PKG_DIR/package.json" ]; then
    echo "    Installing dependencies for $pkg..."
    cd "$WORKSPACE_ROOT/$PRODUCT_PATH/$OUTPUT_DIR/$PKG_DIR"

    # Remove workspace dependencies from package.json before npm install
    #
    # IMPORTANT: Unpublished @qwickapps packages MUST use 'workspace:*' protocol.
    # This is enforced by:
    #   - Pre-commit hook: .husky/pre-commit
    #   - Validation script: .github/scripts/validate-workspace-deps.js
    #   - Build validation: Above (line 66)
    #
    # This approach ensures:
    #   1. Unpublished packages use workspace:* → removed here → npm doesn't try to fetch them
    #   2. Published packages use versions → kept → npm resolves from already-copied node_modules/@qwickapps/
    #   3. No network calls for unpublished packages during deployment
    #
    node -e "
      const fs = require('fs');
      const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));

      // Remove workspace:* protocol dependencies
      // Published @qwickapps packages with version deps are kept and resolved locally
      if (pkg.dependencies) {
        Object.keys(pkg.dependencies).forEach(dep => {
          if (pkg.dependencies[dep].startsWith('workspace:')) {
            delete pkg.dependencies[dep];
          }
        });
      }
      if (pkg.devDependencies) {
        Object.keys(pkg.devDependencies).forEach(dep => {
          if (pkg.devDependencies[dep].startsWith('workspace:')) {
            delete pkg.devDependencies[dep];
          }
        });
      }
      if (pkg.optionalDependencies) {
        Object.keys(pkg.optionalDependencies).forEach(dep => {
          if (pkg.optionalDependencies[dep].startsWith('workspace:')) {
            delete pkg.optionalDependencies[dep];
          }
        });
      }

      fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
    "

    npm install --legacy-peer-deps --production --omit=dev 2>&1 | grep -v "npm warn" || true
    cd "$WORKSPACE_ROOT/$PRODUCT_PATH/$OUTPUT_DIR"
  fi
done
echo "    ✓ Workspace package dependencies installed"

# Verify critical dependencies (dotenv is always required)
echo "  Verifying dependencies..."
MISSING_DEPS=()

# Always check for dotenv
if [ ! -d "node_modules/dotenv" ]; then
  MISSING_DEPS+=("dotenv")
fi

# Only check @qwickapps/server if it's in package.json dependencies
if grep -q '"@qwickapps/server"' package.json; then
  if [ ! -d "node_modules/@qwickapps/server" ]; then
    MISSING_DEPS+=("@qwickapps/server")
  fi
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  echo "Error: Missing critical dependencies:"
  for dep in "${MISSING_DEPS[@]}"; do
    echo "  - $dep"
  done
  exit 1
fi

echo "  All critical dependencies verified"

# Copy build artifacts
echo "  Copying build artifacts..."
if [ -d "../dist" ]; then
  cp -r ../dist .
  echo "    Copied dist/"
fi

# Copy Next.js build (.next directory)
if [ -d "../.next" ]; then
  cp -r ../.next .
  echo "    Copied .next/"
fi

# Copy public directory (Next.js static assets)
if [ -d "../public" ]; then
  cp -r ../public .
  echo "    Copied public/"
fi

# Copy additional build artifacts (dist-ui, dist-ui-lib, etc.)
for build_dir in dist-ui dist-ui-lib; do
  if [ -d "../$build_dir" ]; then
    cp -r "../$build_dir" .
    echo "    Copied $build_dir/"
  fi
done

# Copy website directory (for products with frontend)
if [ -d "../website" ]; then
  cp -r ../website .
  echo "    Copied website/"
fi

# Copy Next.js build output (for Next.js apps)
if [ -d "../.next" ]; then
  cp -r ../.next .
  echo "    Copied .next/"
fi

# Copy public directory (for Next.js apps and static assets)
if [ -d "../public" ]; then
  cp -r ../public .
  echo "    Copied public/"
fi

if [ -f "../Dockerfile" ]; then
  cp ../Dockerfile .
  echo "    Copied Dockerfile"
fi

if [ -f "../captain-definition" ]; then
  cp ../captain-definition .
  echo "    Copied captain-definition"
fi

# Copy tsconfig.json for Payload CLI (needed for migrations)
if [ -f "../tsconfig.json" ]; then
  cp ../tsconfig.json .
  echo "    Copied tsconfig.json"
fi

# Copy payload.config.js from dist (built config for production)
if [ -f "../dist/payload.config.js" ]; then
  cp ../dist/payload.config.js .
  echo "    Copied payload.config.js"
fi

# Copy seed-data directory (for seed scripts - product images, sample data, etc.)
if [ -d "../seed-data" ]; then
  cp -r ../seed-data .
  echo "    Copied seed-data/"
fi

# Copy scripts directory (for seed scripts and utilities)
# Use -P to preserve symlinks (e.g., scripts/media -> ../media)
if [ -d "../scripts" ]; then
  cp -rP ../scripts .
  echo "    Copied scripts/"
fi

echo ""
echo "✓ Standalone deployment package created: $PRODUCT_PATH/$OUTPUT_DIR"

# Return to workspace root
cd "$WORKSPACE_ROOT"
