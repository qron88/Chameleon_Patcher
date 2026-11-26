# External tools: the 7z CLI, Inf2Cat and signtool lookup, the native-command runner, and
# the System32-only path for certutil/bcdedit.
#
# Part of the shared helper library. Do not dot-source this file on its own: load
# Scripts\PatchToolDiscovery.ps1, which loads every part in a fixed order.

$script:PatchToolCache = @{}

function Invoke-NativeTool {
    <#
      Runs a native executable and returns its exit code.

      Native-command stderr is NOT redirected here on purpose. Under Windows PowerShell 5.1
      with $ErrorActionPreference='Stop', redirecting a native command's stderr (2>&1) wraps
      each stderr line in a NativeCommandError ErrorRecord and aborts the script even when the
      exe returns 0 - that is exactly the confirmed bug the old Sign-DriverPackage.ps1 had to
      work around for `signtool verify`. ErrorActionPreference is relaxed for the duration of
      the call as a second safety net, and success/failure is decided solely by the exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments | Out-Host
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-SevenZipCandidatePaths {
    <#
      The fixed places a 7z-compatible CLI is looked for, in order. Machine-wide installs under
      Program Files come FIRST: only an administrator can write there. The per-user WindowsApps
      alias and (in Find-SevenZip) PATH come after, because anything running as this user can
      plant a 7z.exe in either - and the 7z CLI is what decides which bytes land in the package
      AFTER the download's NVIDIA signature has been checked, so it is the last tool that should
      be picked from a user-writable place when an admin-installed one exists. This is the same
      reasoning as Get-SystemToolPath, applied to a tool that has no System32 copy.
    #>
    $list = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $list += (Join-Path $base '7-Zip\7z.exe')
            $list += (Join-Path $base 'NanaZip\7z.exe')
        }
    }
    if ($env:LOCALAPPDATA) { $list += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\7z.exe') }
    return $list
}

function Find-SevenZip {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) { throw "7z CLI not found at the path you passed: $ExplicitPath. There is no fallback route: name a real 7z-compatible CLI with -SevenZipPath, install one (winget install -e --id 7zip.7zip), or unpack the driver by hand and run the pipeline with -SourcePackagePath." }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $cacheKey = '7z'
    if ($script:PatchToolCache.ContainsKey($cacheKey)) {
        $cached = $script:PatchToolCache[$cacheKey]
        if ($cached -and (Test-Path -LiteralPath $cached)) { return $cached }
        $script:PatchToolCache.Remove($cacheKey)
    }

    foreach ($c in (Get-SevenZipCandidatePaths)) {
        if (Test-Path -LiteralPath $c) { $script:PatchToolCache[$cacheKey] = $c; return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:PatchToolCache[$cacheKey] = $cmd.Source; return $cmd.Source }

    throw "No 7z-compatible CLI found (checked 7-Zip/NanaZip under Program Files, the WindowsApps alias, and PATH). Unpacking a driver .exe needs one and there is no fallback: install 7-Zip with  winget install -e --id 7zip.7zip   (NanaZip works too), or unpack the driver by hand and run the pipeline with -SourcePackagePath."
}

function Find-WdkTool {
    <#
      Locates a Windows Kits tool, preferring the NEWEST SDK version and, within that version,
      the x64 build when one exists (Inf2Cat.exe only ships as x86, signtool.exe ships as
      x86/x64/arm64).

      Selection is by parsed [version], not by string-sorting the full path. Older SDK layouts
      put signtool directly under bin\x64\ with no version folder, and a descending string sort
      ranks "...\bin\x64\..." above "...\bin\10.0.26100.0\x64\..." because 'x' > '1' - which on
      a machine carrying both layouts would silently select the OLDER tool. Paths with no
      parseable version segment get a sentinel 0.0 so they rank last but stay usable as a
      fallback.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ExeName,
        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) { throw "$ExeName not found at the path you passed: $ExplicitPath" }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $cacheKey = "wdk:$ExeName"
    if ($script:PatchToolCache.ContainsKey($cacheKey)) {
        $cached = $script:PatchToolCache[$cacheKey]
        if ($cached -and (Test-Path -LiteralPath $cached)) { return $cached }
        $script:PatchToolCache.Remove($cacheKey)
    }

    $roots = @()
    if ($env:WDKContentRoot) { $roots += (Join-Path $env:WDKContentRoot 'bin') }
    $roots += "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $roots += "${env:ProgramFiles}\Windows Kits\10\bin"

    $candidates = @()
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            # ARM builds cannot run on an x64 host; without this filter a version folder that ships
            # x86 and arm64 but no x64 would rank its arm64 copy alongside the x86 one.
            $candidates += @(Get-ChildItem -LiteralPath $root -Filter $ExeName -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\arm(64)?\\' })
        }
    }

    if ($candidates.Count -gt 0) {
        $ranked = foreach ($c in $candidates) {
            $ver = [version]'0.0'
            if ($c.FullName -match '\\(\d+\.\d+\.\d+\.\d+)\\') {
                try { $ver = [version]$Matches[1] } catch { $ver = [version]'0.0' }
            }
            [PSCustomObject]@{
                Path    = $c.FullName
                Version = $ver
                IsX64   = [bool]($c.FullName -match '\\x64\\')
            }
        }
        $best = $ranked |
            Sort-Object -Property @{Expression = 'Version'; Descending = $true},
                                  @{Expression = 'IsX64';   Descending = $true} |
            Select-Object -First 1
        if ($best) {
            $script:PatchToolCache[$cacheKey] = $best.Path
            return $best.Path
        }
    }

    $cmd = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($cmd) { $script:PatchToolCache[$cacheKey] = $cmd.Source; return $cmd.Source }

    throw "$ExeName not found under Windows Kits (checked `$env:WDKContentRoot, Program Files (x86)/Program Files Windows Kits\10\bin, and PATH). Install the Windows Driver Kit / SDK, or pass an explicit path."
}

function Get-MissingToolHelp {
    <#
      Plain-language guidance for a tool that could not be found, for use in the message that
      refuses the run. The point is that the user gets something to act on, not a stack trace. A
      line indented by four is either an address or a terminal command: the GUI shows the address
      and offers to open it in the default browser, and drops the command lines because a window
      with a button that opens the page has no business asking anyone to type anything. A console
      prints both, because whoever is already in a terminal can install it from there. The people
      this message is written for most are the ones with no terminal open.
      the two hard dependencies (Inf2Cat, signtool) both come from the Windows SDK, which is a
      multi-GB install, and the old message said "Windows Driver Kit / SDK" - which reads as
      heavier than what is actually needed. Only the SDK is required; a full WDK is not. When both
      SDK tools are missing they are described once, because there is one package to download and
      one address to hand out.
    #>
    param([string[]]$ToolNames)

    $lines = @()

    # Asked for one tool, a tool-by-tool answer is right. Asked for both SDK tools, it is wrong: the
    # two blocks repeat the same address and the same advice, which reads as two problems when there
    # is one installer to fetch. The pair is described once, naming the two SDK features that have to
    # stay selected - which is the part people actually get wrong.
    $sdkMissing = @($ToolNames | Where-Object { $_ -eq 'Inf2Cat.exe' -or $_ -eq 'signtool.exe' })
    $covered = @()
    if ($sdkMissing.Count -eq 2) {
        $lines += "Both missing tools come from the same package - the"
        $lines += "Windows SDK - so one install fixes both:"
        $lines += ""
        $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
        $lines += ""
        $lines += "Inf2Cat.exe rebuilds nv_disp.cat after the INFs are"
        $lines += "edited, and it ships in the SDK as the 'Windows Driver"
        $lines += "Kit' feature. A full Windows Driver Kit install is NOT"
        $lines += "needed, the SDK alone is enough. signtool.exe signs the"
        $lines += "rebuilt catalog, and it ships as 'Windows SDK Signing"
        $lines += "Tools'. Keep both features selected."
        $lines += ""
        $covered = @('Inf2Cat.exe', 'signtool.exe')
    }

    foreach ($t in $ToolNames) {
        if ($covered -contains $t) { continue }
        switch ($t) {
            'Inf2Cat.exe' {
                $lines += "Inf2Cat.exe - rebuilds nv_disp.cat after the"
                $lines += "INFs are edited. It ships in the Windows SDK, as"
                $lines += "its 'Windows Driver Kit' feature. A full Windows"
                $lines += "Driver Kit install is NOT needed - the SDK alone"
                $lines += "is enough. Install the SDK from:"
                $lines += ""
                $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
                $lines += ""
                $lines += "and keep the 'Windows Driver Kit' selected."
            }
            'signtool.exe' {
                $lines += "signtool.exe - signs the rebuilt catalog. It"
                $lines += "ships in the Windows SDK, as its 'Windows SDK"
                $lines += "Signing Tools' feature. Install the SDK from:"
                $lines += ""
                $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
                $lines += ""
                $lines += "and keep 'Windows SDK Signing Tools' selected."
            }
            '7z' {
                $lines += "A 7z-compatible CLI is required to unpack a driver"
                $lines += ".exe, and none is installed. 7-Zip is free and lives on"
                $lines += "its own download page:"
                $lines += ""
                $lines += "    https://7-zip.org/"
                $lines += ""
                # Both of these lines are indented by four or more, which is how the GUI is told they
                # are for a terminal and not for its window: it shows addresses and leaves these out.
                $lines += "    From a terminal, the same install is:"
                $lines += "        winget install -e --id 7zip.7zip"
                $lines += ""
                $lines += "NanaZip, or any 7z-compatible CLI on PATH, is found the"
                $lines += "same way once it is installed. The other way through is"
                $lines += "-SourcePackagePath: unpack the driver yourself and hand"
                $lines += "this toolkit the folder it produced."
            }
            default {
                $lines += "$t - not found. Pass an explicit path, or install"
                $lines += "the Windows SDK from:"
                $lines += ""
                $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
            }
        }
        $lines += ""
    }
    return $lines
}

function Assert-PatchTools {
    <#
      Resolves every external tool a run will need BEFORE any unpacking/copying happens, so a
      missing SDK fails in seconds rather than after a multi-GB extraction. Returns a hashtable
      of the resolved paths.

      All three are hard requirements when -NeedSevenZip is set, and all three throw with an install
      command rather than falling back to something worse. 7-Zip became one the way Inf2Cat and
      signtool always were: NVIDIA's own installer was tried as the fallback for unpacking, it
      needs elevation and a click, and it unpacks into a system-temp folder a normal run may not be
      allowed to read, so it is not a route this toolkit is willing to depend on. Inf2Cat has no
      substitute either - editing INFs invalidates nv_disp.cat, and Inf2Cat is the only tool that
      rebuilds it.
    #>
    param(
        [switch]$NeedSevenZip,
        [string]$SevenZipPath,
        [string]$Inf2CatPath,
        [string]$SignToolPath
    )

    $resolved = @{}
    if ($NeedSevenZip) {
        # An explicit path is a hard request: if the caller named a CLI, use it and fail loudly
        # when it is not there, rather than quietly substituting a different route.
        # An explicit path is a hard request: if the caller named a CLI, use it and fail loudly
        # when it is not there, rather than quietly substituting a different one.
        $resolved['SevenZip'] = if ($SevenZipPath) { Find-SevenZip -ExplicitPath $SevenZipPath } else { Find-SevenZip }
    }

    $missing = @()
    $inf2cat = $null; $signtool = $null
    try { $inf2cat = Find-WdkTool -ExeName 'Inf2Cat.exe'  -ExplicitPath $Inf2CatPath }  catch { $missing += 'Inf2Cat.exe' }
    try { $signtool = Find-WdkTool -ExeName 'signtool.exe' -ExplicitPath $SignToolPath } catch { $missing += 'signtool.exe' }

    if ($missing.Count -gt 0) {
        $help = Get-MissingToolHelp -ToolNames $missing
        throw ("Required tools not found:`n" + ($help -join "`n") + "`nChecked `$env:WDKContentRoot, Windows Kits\10\bin under Program Files (x86) and Program Files, and PATH. Pass -Inf2CatPath / -SignToolPath to point at them directly.")
    }

    $resolved['Inf2Cat']  = $inf2cat
    $resolved['SignTool'] = $signtool
    return $resolved
}

# --- System tools ----------------------------------------------------------------------------------
function Get-SystemToolPath {
    <#
       Full path of a tool that ships in System32 (certutil.exe, bcdedit.exe). Calling these by bare
       name resolves through the current directory and PATH first, which in an elevated session is
       exactly where a planted copy would sit.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $p = Join-Path ([Environment]::GetFolderPath('System')) $Name
    if (-not (Test-Path -LiteralPath $p)) { throw "$Name not found in $([Environment]::GetFolderPath('System'))." }
    return $p
}
