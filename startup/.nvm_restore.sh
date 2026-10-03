#!/bin/bash
if [ -f "${HOME}/.npmrc.nvmbackup" ]; then
  mv "${HOME}/.npmrc.nvmbackup" "${HOME}/.npmrc" 2>/dev/null || true
fi

export npm_config_cache="${_SAVED_npm_config_cache:-/config/.gmweb/npm-cache}"
export npm_config_prefix="${_SAVED_npm_config_prefix:-/config/.gmweb/npm-global}"
export NPM_CONFIG_CACHE="${_SAVED_NPM_CONFIG_CACHE:-/config/.gmweb/npm-cache}"
export NPM_CONFIG_PREFIX="${_SAVED_NPM_CONFIG_PREFIX:-/config/.gmweb/npm-global}"

unset _SAVED_npm_config_cache _SAVED_npm_config_prefix _SAVED_NPM_CONFIG_CACHE _SAVED_NPM_CONFIG_PREFIX
