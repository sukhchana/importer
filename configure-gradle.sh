#!/bin/bash

set -e  # Exit on any error

# Accept csiAppId as the first argument, default to "empty" if not provided
CSI_APP_ID="${1:-empty}"

echo "Starting Gradle project configuration..."

# Variables for consistent configuration
ARTIFACTORY_REPO_CONFIG='repositories {
  maven {
    url providers.gradleProperty('"'"'citi.artifactoryBaseUrl'"'"').orElse('"'"'https://www.artifactrepository.citigroup.net/artifactory'"'"').map( u -> u + '"'"'/maven-prod-rcmd'"'"')

    credentials {
      username = citiEarUser
      password = citiEarPassword
    }
  }
}'

PLUGIN_MANAGEMENT_CONFIG='pluginManagement {
  repositories {
    maven {
      url providers.gradleProperty('"'"'citi.artifactoryBaseUrl'"'"').orElse('"'"'https://www.artifactrepository.citigroup.net/artifactory'"'"').map( u -> u + '"'"'/maven-prod-rcmd'"'"')

      credentials {
        username = citiEarUser
        password = citiEarPassword
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
        # Ensure a blank line before and after the property
        echo "" >> "$prop_file"
        echo "${prop_name}=${prop_value}" >> "$prop_file"
        echo "" >> "$prop_file"
        echo "   ✓ Added ${prop_name}=${prop_value}"
    else
        # Update existing property
        sed -i.bak "s/^${prop_name}=.*/${prop_name}=${prop_value}/" "$prop_file"
        rm -f "${prop_file}.bak"
        echo "   ✓ Updated ${prop_name}=${prop_value}"
    fi
}

add_property_if_missing "citi.csiAppId" "$CSI_APP_ID" "$temp_props"
add_property_if_missing "citi.projectName" "pv-ingest" "$temp_props"
add_property_if_missing "citi.ignoreWildcardImports" "true" "$temp_props"
add_property_if_missing "citi.useErrorprone" "false" "$temp_props"
add_property_if_missing "conventionPluginVersion" "9.1.1" "$temp_props"

mv "$temp_props" gradle.properties

# 5. Update repositories in all build.gradle files except the root
echo "5. Updating repositories in build.gradle files..."
REPO_BLOCK="$ARTIFACTORY_REPO_CONFIG"
find . -name "build.gradle" -type f ! -path "./build.gradle" | while read -r build_file; do
    echo "   Processing: $build_file"
    # Remove the existing repositories block (greedy, from first to last brace)
    sed -i.bak '/repositories\s*{/,/}/d' "$build_file"
    # Insert the new repositories block after the plugins block if it exists, else at the top
    if grep -q "^plugins" "$build_file"; then
        awk -v repo="$REPO_BLOCK" '
            /^plugins/ { print; plugins=1; next }
            plugins && /^[}]/ { print; print repo; plugins=0; next }
            { print }
        ' "$build_file" > "${build_file}.tmp" && mv "${build_file}.tmp" "$build_file"
    else
        # No plugins block, just prepend
        (echo "$REPO_BLOCK"; cat "$build_file") > "${build_file}.tmp" && mv "${build_file}.tmp" "$build_file"
    fi
    echo "   ✓ Updated repositories in $build_file"
done

# 6. Configure spotless in all build.gradle files except the root
echo "6. Configuring spotless in build.gradle files..."
find . -name "build.gradle" -type f ! -path "./build.gradle" | while read -r build_file; do
    echo "   Processing: $build_file"
    
    # Skip if plugins block contains id 'java-gradle-plugin'
    if awk '
/plugins[[:space:]]*{/ {inblock=1}
inblock && /}/ {inblock=0}
inblock && /id '\''java-gradle-plugin'\''/ {found=1}
END {exit !found}
' "$build_file"; then
        echo "   ✓ Skipped spotless configuration in $build_file (contains id 'java-gradle-plugin')"
        continue
    fi
    
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
echo "- ✓ Updated repositories in all build.gradle files except the root"
echo "- ✓ Configured spotless in all build.gradle files except the root"
echo "- ✓ Removed sonarqube plugins from all build.gradle files"
echo ""
echo "You can now run './gradlew build' to verify the configuration." 

# 8. Create pipeline.yaml
cat > pipeline.yaml << 'EOF'
version: v1
tasks:
  - ref: java-gradle-build
    params: 
      - name: jdk-version
        value: '21'
      - name: publish-artifact
        value: 'true'
EOF

echo "- ✓ Created pipeline.yaml with build pipeline configuration"

# Ensure gradle/wrapper/gradle-wrapper.properties exists and set distributionUrl
WRAPPER_DIR="gradle/wrapper"
WRAPPER_PROPS="$WRAPPER_DIR/gradle-wrapper.properties"
DISTRIBUTION_URL="https://www.artifactrepository.citigroup.net/artifactory/generic-gradle-distributions-remote/gradle-8.14-bin.zip"

mkdir -p "$WRAPPER_DIR"
if [ ! -f "$WRAPPER_PROPS" ]; then
    echo "distributionUrl=$DISTRIBUTION_URL" > "$WRAPPER_PROPS"
    echo "   ✓ Created $WRAPPER_PROPS with distributionUrl"
else
    if grep -q '^distributionUrl=' "$WRAPPER_PROPS"; then
        sed -i.bak "s|^distributionUrl=.*$|distributionUrl=$DISTRIBUTION_URL|" "$WRAPPER_PROPS"
        rm -f "$WRAPPER_PROPS.bak"
        echo "   ✓ Updated distributionUrl in $WRAPPER_PROPS"
    else
        echo "distributionUrl=$DISTRIBUTION_URL" >> "$WRAPPER_PROPS"
        echo "   ✓ Added distributionUrl to $WRAPPER_PROPS"
    fi
fi 

# Run Gradle build at the end

echo ""
echo "▶️  Running './gradlew build' to verify the configuration..."
if ./gradlew build; then
    echo "\n ✓ Gradle build completed successfully!"
else
    echo "\n x Gradle build failed. Please check the output above for details."
    exit 1
fi 

