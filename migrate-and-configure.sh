#!/bin/bash

set -e  # Exit on any error

# Function to display usage
usage() {
    echo "Usage: $0 <sourceRepo> <destinationRepo> <sourcePAT> <destinationPAT> <branch> [<targetBranch>]"
    echo ""
    echo "Parameters:"
    echo "  sourceRepo      - Source GitHub repository URL (https://github.com/user/repo.git)"
    echo "  destinationRepo - Destination GitHub repository URL (https://github.com/user/repo.git)"
    echo "  sourcePAT       - Personal Access Token for source repository"
    echo "  destinationPAT  - Personal Access Token for destination repository"
    echo "  branch          - Branch name to work with and push (source branch)"
    echo "  targetBranch    - (Optional) Target branch name for destination repo (defaults to source branch name)"
    echo ""
    echo "Example:"
    echo "  $0 https://github.com/user/source-repo.git https://github.com/user/dest-repo.git ghp_sourcetoken ghp_desttoken main feature-branch"
    exit 1
}

# Check if required parameters are provided
if [ $# -lt 5 ] || [ $# -gt 6 ]; then
    echo "Error: Invalid number of parameters."
    usage
fi

# Assign parameters to variables
SOURCE_REPO="$1"
DESTINATION_REPO="$2"
SOURCE_PAT="$3"
DESTINATION_PAT="$4"
BRANCH="$5"
if [ $# -eq 6 ]; then
    TARGET_BRANCH="$6"
else
    TARGET_BRANCH="$BRANCH"
fi

# Extract repository name from URL for directory naming
REPO_NAME=$(basename "$SOURCE_REPO" .git)
CLONE_DIR="./cloned-${REPO_NAME}"

# Extract csiid from the destination repo URL (e.g., https://github.com/CitiInternal/<csiid>.somethingelse.git)
DEST_CSIID=$(echo "$DESTINATION_REPO" | sed -n 's#https://github.com/CitiInternal/\([^./]*\)\..*#\1#p')

echo "=== GitHub Repository Migration and Configuration ==="
echo "Source Repository: $SOURCE_REPO"
echo "Destination Repository: $DESTINATION_REPO"
echo "Source Branch: $BRANCH"
echo "Target Branch: $TARGET_BRANCH"
echo "Clone Directory: $CLONE_DIR"
echo ""

# Function to construct authenticated URL
construct_auth_url() {
    local repo_url="$1"
    local pat="$2"
    
    # Remove https:// prefix
    local url_without_protocol="${repo_url#https://}"
    
    # Construct authenticated URL
    echo "https://${pat}@${url_without_protocol}"
}

# Step 1: Clone the source repository
echo "1. Cloning source repository..."
SOURCE_AUTH_URL=$(construct_auth_url "$SOURCE_REPO" "$SOURCE_PAT")

# Remove existing clone directory if it exists
if [ -d "$CLONE_DIR" ]; then
    echo "   Removing existing clone directory: $CLONE_DIR"
    rm -rf "$CLONE_DIR"
fi

git clone "$SOURCE_AUTH_URL" "$CLONE_DIR"
echo "   ✓ Successfully cloned source repository"

# Step 2: Navigate to cloned directory
echo "2. Navigating to cloned repository..."
cd "$CLONE_DIR"
echo "   ✓ Changed to directory: $(pwd)"

# Step 3: Checkout the specified branch
echo "3. Checking out branch: $BRANCH"
if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    git checkout "$BRANCH"
    echo "   ✓ Checked out existing branch: $BRANCH"
elif git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    git checkout "$BRANCH"
    echo "   ✓ Checked out local branch: $BRANCH"
else
    git checkout -b "$BRANCH"
    echo "   ✓ Created and checked out new branch: $BRANCH"
fi

# Step 4: Apply Gradle configuration
echo "4. Applying Gradle configuration..."
# Check if configure-gradle.sh exists in parent directory
if [ -f "../configure-gradle.sh" ]; then
    chmod +x "../configure-gradle.sh"
    "../configure-gradle.sh" "$DEST_CSIID"
    echo "   ✓ Gradle configuration applied successfully"
else
    echo "   ❌ Error: configure-gradle.sh not found in parent directory"
    exit 1
fi

# Step 5: Stage and commit changes
echo "5. Staging and committing changes..."
git add .
if git diff --staged --quiet; then
    echo "   ✓ No changes to commit"
else
    git commit -m "Apply Gradle configuration changes

- Updated build.gradle with required plugins
- Configured settings.gradle with pluginManagement
- Updated gradle.properties with required properties
- Configured repositories and spotless
- Removed .github folder and sonarqube plugins"
    echo "   ✓ Changes committed successfully"
fi

# Step 6: Update remote origin to destination repository and push branch
# Ensure we are in the cloned repo directory before pushing
echo "6. Updating remote origin to destination repository..."
DESTINATION_AUTH_URL=$(construct_auth_url "$DESTINATION_REPO" "$DESTINATION_PAT")
git remote set-url origin "$DESTINATION_AUTH_URL"
echo "   ✓ Remote origin updated to destination repository"

# If the branch is 'main', rename it to 'main_test' before pushing
if [ "$BRANCH" = "main" ]; then
    echo "   Branch is 'main', renaming to 'main_test' before push."
    git branch -m main_test
    BRANCH="main_test"
    # If the user did not specify a target branch, update TARGET_BRANCH as well
    if [ $# -ne 6 ]; then
        TARGET_BRANCH="main_test"
    fi
fi

echo "7. Listing git remote origin before pushing..."
git remote -v

echo "8. Pushing branch to destination repository..."
git push -u origin "$BRANCH:$TARGET_BRANCH"
echo "   ✓ Branch '$BRANCH' pushed successfully to destination repository as '$TARGET_BRANCH'"

echo ""
echo "✅ Migration and configuration complete!"
echo ""
echo "Summary:"
echo "- ✓ Cloned source repository: $SOURCE_REPO"
echo "- ✓ Applied Gradle configuration using configure-gradle.sh"
echo "- ✓ Updated remote origin to: $DESTINATION_REPO"
echo "- ✓ Pushed branch '$BRANCH' to destination repository as '$TARGET_BRANCH'"
echo ""
echo "The repository is now available at: $DESTINATION_REPO"
echo "Working directory: $(pwd)" 