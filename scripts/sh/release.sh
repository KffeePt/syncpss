#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/maintainer_id.sh"

VERSION="${1:-}"
FORCE_OVERWRITE="${FORCE_OVERWRITE:-0}"
MINIMUM_RELEASE_VERSION="1.0.0"
REPO_MANIFEST_FILE="manifest.xml"
MASTER_FINGERPRINT_FILE="master_fingerprint.sha256"
RELEASE_BUNDLE_FILE="syncpss-release-binaries.zip"

release_asset_paths() {
    cat <<'EOF'
bin/syncpss-linux-x86_64
bin/syncpss-linux-x86_64.sha256
bin/manifest.xml
bin/manifest.xml.sha256
bin/install
bin/install.sha256
bin/syncpss-wsl-installer.exe
bin/syncpss-wsl-installer.exe.sha256
bin/installer.sh
bin/installer.sh.sha256
bin/uninstall_syncpss.sh
bin/uninstall_syncpss.sh.sha256
bin/master_fingerprint.sha256
bin/syncpss-release-binaries.zip
EOF
}

signed_release_asset_paths() {
    cat <<'EOF'
bin/syncpss-linux-x86_64
bin/syncpss-wsl-installer.exe
bin/installer.sh
bin/syncpss-release-binaries.zip
EOF
}

release_manifest_asset_names() {
    local asset
    while IFS= read -r asset; do
        [[ -n "$asset" ]] || continue
        basename "$asset"
    done < <(release_asset_paths)

    while IFS= read -r asset; do
        [[ -n "$asset" ]] || continue
        printf '%s.asc\n' "$(basename "$asset")"
    done < <(signed_release_asset_paths)
}

semver_valid() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

semver_cmp() {
    local left="$1"
    local right="$2"
    local la lb lc ra rb rc
    IFS='.' read -r la lb lc <<<"$left"
    IFS='.' read -r ra rb rc <<<"$right"

    if (( la < ra )); then echo -1; return; fi
    if (( la > ra )); then echo 1; return; fi
    if (( lb < rb )); then echo -1; return; fi
    if (( lb > rb )); then echo 1; return; fi
    if (( lc < rc )); then echo -1; return; fi
    if (( lc > rc )); then echo 1; return; fi
    echo 0
}

project_version() {
    sed -nE 's/.*project[[:space:]]*\([[:space:]]*syncpss[[:space:]]+VERSION[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' CMakeLists.txt | head -n1
}

remote_versions() {
    git ls-remote --tags --refs origin "v*" |
        sed -nE 's#.*refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
        awk '!seen[$0]++' |
        sort -t. -k1,1nr -k2,2nr -k3,3nr
}

release_exists() {
    gh release view "$1" >/dev/null 2>&1
}

remote_tag_exists() {
    git ls-remote --exit-code --tags origin "$1" >/dev/null 2>&1
}

local_tag_exists() {
    git rev-parse --verify --quiet "refs/tags/$1" >/dev/null
}

remove_release_version() {
    local tag="$1"

    if release_exists "$tag"; then
        gh release delete "$tag" --yes
    fi

    if remote_tag_exists "$tag"; then
        git push origin ":refs/tags/${tag}"
    fi

    if local_tag_exists "$tag"; then
        git tag -d "$tag" >/dev/null
    fi
}

remove_local_tag_if_present() {
    local tag="$1"
    if local_tag_exists "$tag"; then
        echo "Local tag ${tag} already exists. Replacing it automatically."
        git tag -d "$tag" >/dev/null || {
            echo "Failed to delete local tag ${tag}"
            exit 1
        }
    fi
}

push_release_branch() {
    local branch="$1"
    local release_version="${2:-}"
    local choice

    new_release_pull_request_branch_name() {
        local source_branch="$1"
        local version="${2:-}"
        local safe_source safe_version timestamp

        safe_source="$(printf '%s' "$source_branch" | sed -E 's/[^0-9A-Za-z._-]+/-/g; s/^-+//; s/-+$//')"
        [[ -n "$safe_source" ]] || safe_source="sync"

        if [[ -n "$version" ]]; then
            safe_version="$(printf '%s' "$version" | sed -E 's/[^0-9A-Za-z._-]+/-/g; s/^-+//; s/-+$//')"
        fi
        [[ -n "${safe_version:-}" ]] || safe_version="adhoc"

        timestamp="$(date +%Y%m%d-%H%M%S)"
        printf 'release/%s-v%s-%s\n' "$safe_source" "$safe_version" "$timestamp"
    }

    publish_release_pull_request_branch() {
        local source_branch="$1"
        local version="${2:-}"
        local pr_branch pr_url

        pr_branch="$(new_release_pull_request_branch_name "$source_branch" "$version")"
        echo "Publishing current HEAD to ${pr_branch} so GitHub can review it through a PR..." >&2
        git push origin "HEAD:refs/heads/${pr_branch}" || {
            echo "Failed to publish release branch ${pr_branch}." >&2
            exit 1
        }

        pr_url="$(create_branch_pull_request "main" "$pr_branch" "$version" 1)" || exit 1
        printf '%s|%s|%s\n' "$pr_branch" "1" "$pr_url"
    }

    while true; do
        if git push origin "$branch"; then
            printf '%s|0|\n' "$branch"
            return 0
        fi

        if [[ ! -t 0 ]]; then
            echo "Failed to push branch ${branch}. Remote changes or a ruleset are blocking direct pushes; publish a PR branch manually and retry."
            exit 1
        fi

        echo "Remote branch ${branch} has new commits that are not in your local branch."
        echo "If GitHub requires pull requests on this branch, you can publish a fresh release branch instead."
        echo "Run Push?"
        echo "  [p] Publish a release branch and open PR"
        echo "  [r] Pull with rebase, then retry push"
        echo "  [f] Force push with --force-with-lease"
        echo "  [c] Cancel release"
        read -r -p "Choose push flow [p]: " choice
        choice="${choice:-p}"

        case "${choice,,}" in
            p)
                publish_release_pull_request_branch "$branch" "$release_version"
                return 0
                ;;
            r)
                git pull --rebase origin "$branch" || {
                    echo "Pull --rebase failed for branch ${branch}. Resolve it, then rerun the release."
                    exit 1
                }
                ;;
            f)
                git push --force-with-lease origin "$branch" && return 0
                echo "Force push failed for branch ${branch}."
                exit 1
                ;;
            c)
                echo "Release cancelled before branch push."
                exit 1
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}

assert_expected_origin() {
    local origin
    origin="$(git remote get-url origin)"
    [[ "$origin" =~ KffeePt[/\\:]syncpss(\.git)?$ ]] || {
        echo "This release script expects origin to point at KffeePt/syncpss. Current origin: ${origin}"
        exit 1
    }
}

prompt_yes_no() {
    local message="$1"
    local default_yes="${2:-1}"
    local suffix answer

    if [[ "$default_yes" == "1" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    read -r -p "${message} ${suffix} " answer
    if [[ -z "$answer" ]]; then
        [[ "$default_yes" == "1" ]]
        return
    fi

    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

ensure_clean_or_commit() {
    local release_version="$1"
    local status commit_message default_message

    status="$(git status --short)"
    [[ -z "$status" ]] && return

    echo
    echo "Working tree has uncommitted changes:"
    while IFS= read -r line; do
        [[ -n "$line" ]] && echo "  $line"
    done <<<"$status"
    echo

    if ! prompt_yes_no "Stage all changes and create a commit before releasing?" 1; then
        echo "Release cancelled because the worktree is dirty."
        exit 1
    fi

    git add -A

    default_message="syncpss: release v${release_version}"
    read -r -p "Commit message [${default_message}] " commit_message
    commit_message="${commit_message:-$default_message}"

    git commit -m "$commit_message"

    status="$(git status --short)"
    [[ -z "$status" ]] || { echo "Worktree is still dirty after committing. Resolve the remaining changes and retry."; exit 1; }
}

resolve_requested_version() {
    local requested="$1"
    local project="$2"
    local current="$3"

    if [[ -n "$requested" ]]; then
        semver_valid "$requested" || { echo "Version must use x.y.z format, for example 1.0.0"; exit 1; }
        [[ "$(semver_cmp "$requested" "$MINIMUM_RELEASE_VERSION")" -ge 0 ]] || { echo "Minimum release version is ${MINIMUM_RELEASE_VERSION}"; exit 1; }
        echo "$requested"
        return
    fi

    if [[ -n "$current" ]]; then
        echo "$current"
        return
    fi

    if [[ -n "$project" ]] && semver_valid "$project" && [[ "$(semver_cmp "$project" "$MINIMUM_RELEASE_VERSION")" -ge 0 ]]; then
        echo "No published release exists yet. Using project version ${project} for the first release." >&2
        echo "$project"
        return
    fi

    echo "No published release exists yet. Falling back to first release version ${MINIMUM_RELEASE_VERSION}." >&2
    echo "${MINIMUM_RELEASE_VERSION}"
}

prompt_release_version_choice() {
    local current="$1"
    local project="$2"
    local selection entered

    if [[ -z "$current" ]]; then
        resolve_requested_version "$VERSION" "$project" "$current"
        return
    fi

    echo
    echo "No release version was provided."
    echo "Current published version: v${current}"
    echo "Minimum allowed version: ${MINIMUM_RELEASE_VERSION}"
    echo "  [1] Overwrite current release v${current}"
    echo "  [2] Enter a new release version"

    while true; do
        read -r -p "Choose release version flow [1]: " selection
        selection="${selection:-1}"
        case "$selection" in
            1)
                echo "$current"
                return
                ;;
            2)
                while true; do
                    read -r -p "Enter new release version (minimum ${MINIMUM_RELEASE_VERSION}): " entered
                    [[ -n "$entered" ]] || { echo "Please enter a version."; continue; }
                    resolve_requested_version "$entered" "$project" "$current"
                    return
                done
                ;;
        esac
    done
}

repo_id_seed() {
    local seed
    seed="$(maintainer_current_id "$(pwd)" || true)"
    if [[ -n "${seed}" ]]; then
        echo "${seed}"
        return 0
    fi

    if seed="$(maintainer_prompt_initialize "$(pwd)")"; then
        echo "${seed}"
        return 0
    fi

    echo "Missing SYNCPSS_MAINTAINER_ID. Set it from config/maintainer_id.sha256 or run bash scripts/sh/set_fingerprint.sh"
    exit 1
}

repo_id_seed_hash() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

update_repo_manifest() {
    local version="$1"
    local repo_id_hash="$2"
    local updated_at asset_xml
    updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    asset_xml="$(
        while IFS= read -r asset_name; do
            [[ -n "$asset_name" ]] || continue
            printf '    <asset name="%s" />\n' "$asset_name"
        done < <(release_manifest_asset_names)
    )"

    cat > "${REPO_MANIFEST_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<syncpss-manifest>
  <release>
    <name>Release v${version}</name>
    <tag>v${version}</tag>
    <version>${version}</version>
    <updated_at>${updated_at}</updated_at>
  </release>
  <repository>
    <owner>KffeePt</owner>
    <name>syncpss</name>
    <id_hash>${repo_id_hash}</id_hash>
  </repository>
  <assets>
${asset_xml}
  </assets>
</syncpss-manifest>
EOF
}

release_master_fingerprint() {
    local temp_payload
    temp_payload="$(mktemp)"
    cat \
      "bin/syncpss-linux-x86_64" \
      "bin/install" \
      "bin/installer.sh" \
      "bin/uninstall_syncpss.sh" > "${temp_payload}"
    sha256sum "${temp_payload}" | awk '{print $1}'
    rm -f "${temp_payload}"
}

write_master_fingerprint_assets() {
    local fingerprint
    fingerprint="$(release_master_fingerprint)"
    printf '%s  master_fingerprint.sha256\n' "$fingerprint" > "${MASTER_FINGERPRINT_FILE}"
    mkdir -p bin
    printf '%s  master_fingerprint.sha256\n' "$fingerprint" > "bin/${MASTER_FINGERPRINT_FILE}"
}

write_release_bundle() {
    local staging_root bundle_path
    local bundle_entries=(
      "bin/syncpss-linux-x86_64"
      "bin/install"
      "bin/syncpss-wsl-installer.exe"
      "bin/installer.sh"
      "bin/uninstall_syncpss.sh"
    )

    command -v zip >/dev/null 2>&1 || { echo "zip is required to create ${RELEASE_BUNDLE_FILE}"; exit 1; }

    for asset in "${bundle_entries[@]}"; do
        [[ -f "${asset}" ]] || { echo "Cannot create release bundle. Missing file: ${asset}"; exit 1; }
    done

    staging_root="$(mktemp -d)"
    bundle_path="bin/${RELEASE_BUNDLE_FILE}"
    rm -f "${bundle_path}"
    trap 'rm -rf "'"${staging_root}"'"' RETURN

    for asset in "${bundle_entries[@]}"; do
        cp -f "${asset}" "${staging_root}/$(basename "${asset}")"
    done

    (
        cd "${staging_root}"
        zip -q -r "${PWD}/${RELEASE_BUNDLE_FILE}" ./*
    )
    mv -f "${staging_root}/${RELEASE_BUNDLE_FILE}" "${bundle_path}"
    rm -rf "${staging_root}"
    trap - RETURN
}

remove_stale_release_signatures() {
    find bin -maxdepth 1 -type f -name '*.asc' -delete 2>/dev/null || true
}

assert_gpg_signing_ready() {
    command -v gpg >/dev/null 2>&1 || { echo "gpg is required for signed tags and detached release signatures."; exit 1; }

    local signing_key
    signing_key="$(git config --get user.signingkey || true)"
    if [[ -n "$signing_key" ]]; then
        gpg --list-secret-keys --keyid-format=long --with-colons "$signing_key" 2>/dev/null | grep -q '^sec:' || {
            echo "No usable GPG secret key was found for git user.signingkey '$signing_key'."
            exit 1
        }
        return
    fi

    gpg --list-secret-keys --keyid-format=long --with-colons 2>/dev/null | grep -q '^sec:' || {
        echo "No usable GPG secret key was found. Configure one before releasing."
        exit 1
    }
}

write_detached_release_signatures() {
    local asset signature
    for asset in "$@"; do
        signature="${asset}.asc"
        rm -f -- "$signature"
        echo "Signing asset: $(basename "$asset")"
        gpg --yes --armor --detach-sign --output "$signature" "$asset"
        gpg --verify "$signature" "$asset" >/dev/null 2>&1 || {
            echo "Detached signature verification failed for ${asset}"
            exit 1
        }
    done
}

create_signed_release_tag() {
    local tag="$1"
    local signing_key
    signing_key="$(git config --get user.signingkey || true)"

    if [[ -n "$signing_key" ]]; then
        git -c gpg.format=openpgp tag -s -u "$signing_key" "$tag" -m "Release ${tag}"
    else
        git -c gpg.format=openpgp tag -s "$tag" -m "Release ${tag}"
    fi

    git -c gpg.format=openpgp tag -v "$tag" >/dev/null 2>&1 || {
        echo "Signed tag verification failed for ${tag}"
        exit 1
    }
}

create_github_release_with_assets() {
    local tag="$1"
    shift
    local asset asset_name

    echo "Creating GitHub release metadata for ${tag}..."
    gh release create "$tag" \
      --verify-tag \
      --latest \
      --title "Release ${tag}" \
      --generate-notes

    for asset in "$@"; do
        asset_name="$(basename "$asset")"
        echo "Uploading asset: ${asset_name}"
        gh release upload "$tag" "$asset" --clobber
    done
}

existing_pull_request_url() {
    local base="$1"
    local head="$2"
    local url

    url="$(gh pr list --base "$base" --head "$head" --state open --limit 1 --json url --jq '.[0].url' 2>/dev/null || true)"
    url="${url%$'\r'}"
    url="${url%$'\0'}"
    if [[ "$url" == "null" ]]; then
        url=""
    fi
    printf '%s' "$url"
}

create_branch_pull_request() {
    local base="$1"
    local head="$2"
    local release_version="${3:-}"
    local skip_prompt="${4:-0}"
    local existing_url title body

    existing_url="$(existing_pull_request_url "$base" "$head")"
    if [[ -n "$existing_url" ]]; then
        echo "Open pull request already exists: ${existing_url}" >&2
        printf '%s' "$existing_url"
        return 0
    fi

    if [[ "$skip_prompt" != "1" ]] && ! prompt_yes_no "Create a pull request from ${head} into ${base} now?" 1; then
        echo "Pull request creation skipped." >&2
        return 0
    fi

    if [[ -n "$release_version" ]]; then
        title="syncpss: release v${release_version} from ${head}"
    else
        title="syncpss: sync ${head} into ${base}"
    fi

    body="This pull request was created automatically by scripts/cd.bat after pushing branch '${head}'."
    body+=$'\n\nGitHub Actions will run the branch push checks and the pull request checks automatically.'

    echo "Creating pull request from ${head} into ${base}..." >&2
    if ! gh pr create --base "$base" --head "$head" --title "$title" --body "$body"; then
        echo "Pull request creation failed." >&2
        return 1
    fi

    existing_url="$(existing_pull_request_url "$base" "$head")"
    if [[ -n "$existing_url" ]]; then
        echo "Pull request created: ${existing_url}" >&2
    fi
    printf '%s' "$existing_url"
}

commit_release_metadata_if_needed() {
    local release_version="$1"
    git add -- "manifest.xml"
    git add -f -- "${MASTER_FINGERPRINT_FILE}"
    local status
    status="$(git status --short -- "manifest.xml" "${MASTER_FINGERPRINT_FILE}")"
    [[ -z "$status" ]] && return
    git commit -m "syncpss: refresh release metadata for v${release_version}"
}

command -v gh >/dev/null 2>&1 || { echo "gh is required."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated. Run: gh auth login"; exit 1; }

assert_expected_origin

PROJECT_VERSION="$(project_version || true)"
CURRENT_VERSION="$(remote_versions | head -n1 || true)"
if [[ -z "$VERSION" ]]; then
    REQUESTED_VERSION="$(prompt_release_version_choice "$CURRENT_VERSION" "$PROJECT_VERSION")"
else
    REQUESTED_VERSION="$(resolve_requested_version "$VERSION" "$PROJECT_VERSION" "$CURRENT_VERSION")"
fi
REPO_ID_SEED="$(repo_id_seed)"
REPO_ID_SEED_HASH="$(repo_id_seed_hash "$REPO_ID_SEED")"
EXPECTED_REPO_ID_HASH="$(maintainer_expected_hash "$(pwd)")"
[[ "$REPO_ID_SEED_HASH" == "$EXPECTED_REPO_ID_HASH" ]] || { echo "SYNCPSS_MAINTAINER_ID hash mismatch. Expected ${EXPECTED_REPO_ID_HASH} but found ${REPO_ID_SEED_HASH} against config/maintainer_id.sha256."; exit 1; }
update_repo_manifest "$REQUESTED_VERSION" "$REPO_ID_SEED_HASH"

BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { echo "Release must be created from a named branch, not a detached HEAD."; exit 1; }

ensure_clean_or_commit "$REQUESTED_VERSION"

OVERWRITE_EXISTING=0
if [[ -z "$VERSION" && -n "$CURRENT_VERSION" ]]; then
    OVERWRITE_EXISTING=1
    echo "No version was provided. Releasing by overwriting the current published version v${REQUESTED_VERSION}."
elif [[ -n "$CURRENT_VERSION" ]]; then
    comparison="$(semver_cmp "$REQUESTED_VERSION" "$CURRENT_VERSION")"
    if [[ "$comparison" == "-1" ]]; then
        TAG="v${REQUESTED_VERSION}"
        if ! release_exists "$TAG" && ! remote_tag_exists "$TAG" && ! local_tag_exists "$TAG"; then
            echo "v${REQUESTED_VERSION} is older than the current release v${CURRENT_VERSION}. Older versions can only be recreated by overwriting an existing release version."
            exit 1
        fi
        OVERWRITE_EXISTING=1
        echo "Requested version v${REQUESTED_VERSION} is older than current v${CURRENT_VERSION}. Overwriting release v${REQUESTED_VERSION} automatically."
    elif [[ "$comparison" == "0" ]]; then
        OVERWRITE_EXISTING=1
        echo "Requested version v${REQUESTED_VERSION} matches the current release. Overwriting it automatically."
    else
        echo "Requested version v${REQUESTED_VERSION} is newer than current v${CURRENT_VERSION}. Creating a new release automatically."
    fi
else
    echo "No published release exists yet. Creating initial release v${REQUESTED_VERSION}."
fi

TAG="v${REQUESTED_VERSION}"

echo "Refreshing Linux release artifacts..."
bash scripts/sh/build.sh
write_master_fingerprint_assets
write_release_bundle
commit_release_metadata_if_needed "$REQUESTED_VERSION"

required_assets=(
  $(release_asset_paths)
)

for asset in "${required_assets[@]}"; do
    [[ -f "${asset}" ]] || { echo "Missing release asset: ${asset}"; exit 1; }
done

assert_gpg_signing_ready
remove_stale_release_signatures
mapfile -t signed_assets < <(signed_release_asset_paths)
write_detached_release_signatures "${signed_assets[@]}"
release_assets=("${required_assets[@]}")
for asset in "${signed_assets[@]}"; do
    release_assets+=("${asset}.asc")
done

echo "Release assets staged for upload:"
for asset in "${release_assets[@]}"; do
    echo "  - $(basename "$asset")"
done

echo "Pushing branch ${BRANCH}, then tagging ${TAG} and creating the GitHub release..."
push_result="$(push_release_branch "$BRANCH" "$REQUESTED_VERSION")"
push_branch="${push_result%%|*}"
push_rest="${push_result#*|}"
push_opened_pr="${push_rest%%|*}"
push_pr_url="${push_result##*|}"

if [[ "$push_opened_pr" == "1" ]]; then
    echo
    echo "Direct push to ${BRANCH} was blocked, so a reviewable PR branch was published instead."
    if [[ -n "$push_pr_url" ]]; then
        echo "Review and merge the release PR here: ${push_pr_url}"
    fi
    echo "After that PR lands on main, rerun scripts/cd.bat ${REQUESTED_VERSION} to publish the signed release."
    exit 0
fi

if [[ "$OVERWRITE_EXISTING" == "1" ]]; then
    remove_release_version "$TAG"
else
    remove_local_tag_if_present "$TAG"
    remote_tag_exists "$TAG" && { echo "Tag ${TAG} already exists on origin."; exit 1; }
    release_exists "$TAG" && { echo "Release ${TAG} already exists on GitHub."; exit 1; }
fi

create_signed_release_tag "$TAG"
git push origin "$TAG"
create_github_release_with_assets "$TAG" "${release_assets[@]}"

if [[ "$BRANCH" != "main" ]]; then
    if ! create_branch_pull_request "main" "$BRANCH" "$REQUESTED_VERSION"; then
        echo "Warning: release completed, but automatic pull request creation failed."
    fi
fi

if [[ "$OVERWRITE_EXISTING" == "1" ]]; then
    echo "Release overwritten: ${TAG}"
else
    echo "Release created: ${TAG}"
fi
echo "Done. Watch: https://github.com/KffeePt/syncpss/actions"
