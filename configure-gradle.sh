#!/bin/bash

set -e  # Exit on any error

echo "Starting Gradle project configuration..."

# Variables for consistent configuration
ARTIFACTORY_REPO_CONFIG='repositories {
  maven {
    url providers.gradleProperty('"'"'citi.artifactoryBaseUrl'"'"').orElse('"'"'https://www.artifactory.citigroup.net/artifactory'"'"').map( u -> u + '"'"'/maven-prod-rcmd'"'"')

    credentials {
      username = citiEarUser
      password = citiEarPassword
    }
  }
}'

PLUGIN_MANAGEMENT_CONFIG='pluginManagement {
  repositories {
    maven {
      url providers.gradleProperty('"'"'citi.artifactoryBaseUrl'"'"').orElse('"'"'https://www.artifactory.citigroup.net/artifactory'"'"').map( u -> u + '"'"'/maven-prod-rcmd'"'"')

      credentials {
        username = citiEarUser
        password = citiEarPassword
      }
    }
  }

  plugins {
    id '"'"'com.citi.171981.java.convention'"'"' version conventionPluginVersion
  }
}'

# 1. Ensure root build.gradle exists with required plugin
echo "1. Configuring root build.gradle..."
cat > build.gradle << 'EOF'
plugins {
    id 'com.citi.171981.java.convention'
}
EOF
echo "   ✓ Root build.gradle created/updated"

# 2. Update all settings.gradle files with pluginManagement
echo "2. Updating settings.gradle files..."
find . -name "settings.gradle" -type f | while read -r settings_file; do
    echo "   Processing: $settings_file"
    
    # Create a temporary file
    temp_file=$(mktemp)
    
    # Add pluginManagement at the beginning
    echo "$PLUGIN_MANAGEMENT_CONFIG" > "$temp_file"
    echo "" >> "$temp_file"
    
    # Add existing content, but skip if pluginManagement already exists
    if ! grep -q "pluginManagement" "$settings_file"; then
        cat "$settings_file" >> "$temp_file"
        mv "$temp_file" "$settings_file"
        echo "   ✓ Added pluginManagement to $settings_file"
    else
        # Replace existing pluginManagement block
        sed '/pluginManagement/,/^}/d' "$settings_file" > "${temp_file}.content"
        echo "$PLUGIN_MANAGEMENT_CONFIG" > "$temp_file"
        echo "" >> "$temp_file"
        cat "${temp_file}.content" >> "$temp_file"
        mv "$temp_file" "$settings_file"
        rm -f "${temp_file}.content"
        echo "   ✓ Replaced pluginManagement in $settings_file"
    fi
done

# 3. Remove .github folder
echo "3. Removing .github folder..."
if [ -d ".github" ]; then
    rm -rf .github
    echo "   ✓ .github folder removed"
else
    echo "   ✓ .github folder not found (already removed)"
fi

# 4. Update gradle.properties
echo "4. Updating gradle.properties..."
# Backup existing gradle.properties
if [ -f "gradle.properties" ]; then
    cp gradle.properties gradle.properties.backup
fi

# Read existing properties and add required ones
temp_props=$(mktemp)

# Copy existing properties
if [ -f "gradle.properties" ]; then
    cat gradle.properties > "$temp_props"
else
    touch "$temp_props"
fi

# Add required properties if they don't exist
add_property_if_missing() {
    local prop_name="$1"
    local prop_value="$2"
    local prop_file="$3"
    
    if ! grep -q "^${prop_name}=" "$prop_file"; then
        echo "${prop_name}=${prop_value}" >> "$prop_file"
        echo "   ✓ Added ${prop_name}=${prop_value}"
    else
        # Update existing property
        sed -i.bak "s/^${prop_name}=.*/${prop_name}=${prop_value}/" "$prop_file"
        rm -f "${prop_file}.bak"
        echo "   ✓ Updated ${prop_name}=${prop_value}"
    fi
}

add_property_if_missing "citi.csiAppId" "empty" "$temp_props"
add_property_if_missing "citi.projectName" "pv-ingest" "$temp_props"
add_property_if_missing "citi.ignoreWildcardImports" "true" "$temp_props"
add_property_if_missing "citi.useErrorprone" "false" "$temp_props"

mv "$temp_props" gradle.properties

# 5. Update repositories in all build.gradle files
echo "5. Updating repositories in build.gradle files..."
find . -name "build.gradle" -type f | while read -r build_file; do
    echo "   Processing: $build_file"
    
    # Create temporary file
    temp_file=$(mktemp)
    
    # Process the build.gradle file
    awk -v repo_config="$ARTIFACTORY_REPO_CONFIG" '
    /^repositories\s*{/ {
        print repo_config
        brace_count = 1
        in_repositories = 1
        next
    }
    in_repositories == 1 {
        if ($0 ~ /{/) brace_count++
        if ($0 ~ /}/) brace_count--
        if (brace_count == 0) {
            in_repositories = 0
        }
        next
    }
    { print }
    ' "$build_file" > "$temp_file"
    
    mv "$temp_file" "$build_file"
    echo "   ✓ Updated repositories in $build_file"
done

# 6. Configure spotless in all build.gradle files
echo "6. Configuring spotless in build.gradle files..."
find . -name "build.gradle" -type f | while read -r build_file; do
    echo "   Processing: $build_file"
    
    # Check if spotless exists and update or add it
    if grep -q "spotless" "$build_file"; then
        # Replace existing spotless configuration
        temp_file=$(mktemp)
        awk '
        /^spotless\s*{/ {
            print "spotless {"
            print "    enforceCheck false"
            print "}"
            brace_count = 1
            in_spotless = 1
            next
        }
        in_spotless == 1 {
            if ($0 ~ /{/) brace_count++
            if ($0 ~ /}/) brace_count--
            if (brace_count == 0) {
                in_spotless = 0
            }
            next
        }
        { print }
        ' "$build_file" > "$temp_file"
        mv "$temp_file" "$build_file"
        echo "   ✓ Updated spotless configuration in $build_file"
    else
        # Add spotless configuration at the end
        echo "" >> "$build_file"
        echo "spotless {" >> "$build_file"
        echo "    enforceCheck false" >> "$build_file"
        echo "}" >> "$build_file"
        echo "   ✓ Added spotless configuration to $build_file"
    fi
done

# 7. Remove sonarqube plugins from all build.gradle files
echo "7. Removing sonarqube plugins from build.gradle files..."
find . -name "build.gradle" -type f | while read -r build_file; do
    echo "   Processing: $build_file"
    
    # Remove sonarqube plugin lines
    temp_file=$(mktemp)
    grep -v "org.sonarqube" "$build_file" > "$temp_file" || true
    mv "$temp_file" "$build_file"
    echo "   ✓ Removed sonarqube plugins from $build_file"
done

echo ""
echo "✅ Gradle configuration complete!"
echo ""
echo "Summary of changes:"
echo "- ✓ Created/updated root build.gradle with required plugin"
echo "- ✓ Updated all settings.gradle files with pluginManagement"
echo "- ✓ Removed .github folder"
echo "- ✓ Updated gradle.properties with required properties"
echo "- ✓ Updated repositories in all build.gradle files"
echo "- ✓ Configured spotless in all build.gradle files"
echo "- ✓ Removed sonarqube plugins from all build.gradle files"
echo ""
echo "You can now run './gradlew build' to verify the configuration." 