#!/usr/bin/env bash

####################################################################
# START of GitHub Action specific code

# This script assumes that node, curl, sudo, python and jq are installed.

# If you want to run this script in a non-GitHub Action environment,
# all you'd need to do is set the following environment variables and
# delete the code below. Everything else is platform independent.
#
# Here, we're translating the GitHub action input arguments into environment variables
# for this script to use.
[[ -n "$INPUT_STORE" ]]             && export SHOP_STORE="$INPUT_STORE"
[[ -n "$INPUT_PASSWORD" ]]          && export SHOP_PASSWORD="$INPUT_PASSWORD"
[[ -n "$INPUT_PRODUCT_HANDLE" ]]    && export SHOP_PRODUCT_HANDLE="$INPUT_PRODUCT_HANDLE"
[[ -n "$INPUT_COLLECTION_HANDLE" ]] && export SHOP_COLLECTION_HANDLE="$INPUT_COLLECTION_HANDLE"

# Optional, these are used by Lighthouse CI to add pass/fail checks on
# the GitHub Pull Request.
[[ -n "$INPUT_LHCI_GITHUB_APP_TOKEN" ]] && export LHCI_GITHUB_APP_TOKEN="$INPUT_LHCI_GITHUB_APP_TOKEN"
[[ -n "$INPUT_LHCI_GITHUB_TOKEN" ]]     && export LHCI_GITHUB_TOKEN="$INPUT_LHCI_GITHUB_TOKEN"

# Optional, these are used
[[ -n "$INPUT_LHCI_MIN_SCORE_PERFORMANCE" ]]   && export LHCI_MIN_SCORE_PERFORMANCE="$INPUT_LHCI_MIN_SCORE_PERFORMANCE"
[[ -n "$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY" ]] && export LHCI_MIN_SCORE_ACCESSIBILITY="$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY"

# Add global node bin to PATH (from the Dockerfile)
export PATH="$PATH:$npm_config_prefix/bin"

# END of GitHub Action Specific Code
####################################################################

# Portable code below
set -eou pipefail

log() {
  echo "$@" 1>&2
}

step() {
  cat <<-EOF 1>&2
	==============================
	$1
	EOF
}

is_installed() {
  # This works with scripts and programs. For more info, check
  # http://goo.gl/B9683D
  type $1 &> /dev/null 2>&1
}

cleanup() {
  if [[ -f "lighthouserc.yml" ]]; then
    rm "lighthouserc.yml"
  fi

  if [[ -f "setPreviewCookies.js" ]]; then
    rm "setPreviewCookies.js"
  fi

  return $1
}

trap 'cleanup $?' EXIT

if ! is_installed lhci; then
  step "Installing Lighthouse CI"
  log npm install -g @lhci/cli@0.7.x puppeteer
  npm install -g @lhci/cli@0.7.x puppeteer
fi

if ! is_installed shopify; then
  step "Installing Shopify CLI"
  log "gem install shopify"
  gem install shopify
fi

step "Configuring shopify CLI"

# Disable analytics
mkdir -p ~/.config/shopify && cat <<-YAML > ~/.config/shopify/config
[analytics]
enabled = false
YAML

# Secret environment variable that turns shopify CLI into CI mode that accepts environment credentials
export CI=1
export SHOPIFY_SHOP="${SHOP_STORE#*(https://|http://)}"

host="https://${SHOP_STORE#*(https://|http://)}"

# Use the $SHOP_PASSWORD defined as a Github Secret for password protected stores.
[[ -z ${SHOP_PASSWORD+x} ]] && shop_password='' || shop_password="$SHOP_PASSWORD"

log "Will run Lighthouse CI on $host"

step "Configuring Lighthouse CI"

if [[ -n "${SHOP_PRODUCT_HANDLE+x}" ]]; then
  product_handle="$SHOP_PRODUCT_HANDLE"
fi

if [[ -n "${SHOP_COLLECTION_HANDLE+x}" ]]; then
  collection_handle="$SHOP_COLLECTION_HANDLE"
fi

# Disable redirects + preview bar
min_score_performance="${LHCI_MIN_SCORE_PERFORMANCE:-0.6}"
min_score_accessibility="${LHCI_MIN_SCORE_ACCESSIBILITY:-0.9}"

cat <<- EOF > lighthouserc.yml
ci:
  collect:
    url:
      - "$host/"
      - "$host/products/$product_handle"
      - "$host/collections/$collection_handle"
    puppeteerScript: './setPreviewCookies.js'
    puppeteerLaunchOptions:
      args:
        - "--no-sandbox"
        - "--disable-setuid-sandbox"
        - "--disable-dev-shm-usage"
        - "--disable-gpu"
  upload:
    target: temporary-public-storage
  assert:
    assertions:
      "categories:performance":
        - error
        - minScore: $min_score_performance
          aggregationMethod: median-run
      "categories:accessibility":
        - error
        - minScore: $min_score_accessibility
          aggregationMethod: median-run
EOF

cat <<-EOF > setPreviewCookies.js
module.exports = async (browser) => {
  // launch browser for LHCI
  console.error('Getting a new page...');
  const page = await browser.newPage();
  // Get password cookie if password is set
  if ('$shop_password' !== '') {
    console.error('Getting password cookie...');
    await page.goto('$host/password');
    await page.waitForSelector('form[action*=password] input[type="password"]');
    await page.\$eval('form[action*=password] input[type="password"]', input => input.value = '$shop_password');
    await Promise.all([
      page.waitForNavigation(),
      page.\$eval('form[action*=password]', form => form.submit()),
    ])
  }
  // Get preview cookie
  console.error('Getting preview cookie...');
  await page.goto('$host');
  // close session for next run
  await page.close();
};
EOF

step "Running Lighthouse CI"
lhci autorun
