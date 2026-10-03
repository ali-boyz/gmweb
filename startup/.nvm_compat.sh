#!/bin/bash
export _SAVED_npm_config_cache="${npm_config_cache:-}"
export _SAVED_npm_config_prefix="${npm_config_prefix:-}"
export _SAVED_NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-}"
export _SAVED_NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-}"

unset npm_config_cache npm_config_prefix NPM_CONFIG_CACHE NPM_CONFIG_PREFIX

if [ -f "${HOME}/.npmrc" ]; then
  mv "${HOME}/.npmrc" "${HOME}/.npmrc.nvmbackup" 2>/dev/null || true
fi
