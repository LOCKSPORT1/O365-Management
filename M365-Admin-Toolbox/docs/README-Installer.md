# Installation and bootstrap

## Install-M365AdminToolbox.ps1
Copies the toolbox into a PowerShell module path, optionally installs dependencies, and can import the module after install.

## Bootstrap-M365AdminToolbox.ps1
Imports the module from the current package location and can install dependencies or initialize the secret store.

## Why a manifest matters
The module manifest defines the root module, version, compatibility, and exported functions for predictable enterprise import behavior.

## Advanced-function module use
After installation, import the manifest and use exported functions rather than only calling loose script files.
