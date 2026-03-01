# escape=`
ARG BASE_IMAGE=nationalinstruments/labview:2026q1-windows
FROM ${BASE_IMAGE}

SHELL ["powershell", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

ARG NODE_VERSION=22.11.0
ENV NODE_VERSION=${NODE_VERSION}

RUN $zip = \"$env:TEMP\\node.zip\"; `
    Invoke-WebRequest -Uri (\"https://nodejs.org/dist/v{0}/node-v{0}-win-x64.zip\" -f $env:NODE_VERSION) -OutFile $zip; `
    Expand-Archive -LiteralPath $zip -DestinationPath 'C:\\nodejs' -Force; `
    Remove-Item -LiteralPath $zip -Force; `
    $dir = Get-ChildItem -LiteralPath 'C:\\nodejs' -Directory | Select-Object -First 1; `
    if (-not $dir) { throw 'Node archive extraction failed.' }; `
    $target = 'C:\\nodejs\\current'; `
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }; `
    Move-Item -LiteralPath $dir.FullName -Destination $target

ENV PATH=\"C:\\nodejs\\current;C:\\nodejs\\current\\node_modules\\npm\\bin;${PATH}\"

RUN node --version; npm --version
