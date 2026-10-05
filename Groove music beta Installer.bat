@echo off
setlocal
title Install Groove Music Beta
cd /d "%~dp0"
set "SELF=%~f0"
set "GROOVE_BAT_DIR=%~dp0"
set "PSARGS=-BlockStoreUpdates"
echo.
call :run
set "RC=%errorlevel%"
if not "%RC%"=="2" goto :end
echo.
choice /c SN /m "Il Groove originale non e' disponibile. Installare invece il Lettore multimediale (successore di Groove)"
if errorlevel 2 goto :end
set "PSARGS=-AllowLatest"
call :run
set "RC=%errorlevel%"

:end
echo.
pause
exit /b %RC%

:run
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:SELF); $m='#'+'#PSBEGIN'+'#'+'#'; $i=$c.LastIndexOf($m); $sb=[ScriptBlock]::Create($c.Substring($i+$m.Length)); & $sb %PSARGS%"
exit /b %errorlevel%

##PSBEGIN##
<#
.SYNOPSIS
    Installa Groove Music ORIGINALE (Microsoft.ZuneMusic 10.x) su Windows 10, in modo automatico.

.DESCRIPTION
    Dal 2022 l'app Microsoft.ZuneMusic e' stata trasformata in "Lettore multimediale" (versione 11.x).
    Il Groove originale corrisponde alle versioni 10.x.

    Lo script:
      1) Controlla cosa hai installato adesso.
      2) Raccoglie i pacchetti disponibili da DUE fonti:
           - la cartella dello script (file .appx/.msix/.appxbundle/.msixbundle che ci metti tu)
           - online, tramite store.rg-adguard.net (link ai server ufficiali Microsoft),
             con intestazioni da browser e fallback su curl.exe
      3) Sceglie il Groove 10.x piu' recente e le dipendenze (VCLibs, NET.Native, UI.Xaml)
         per la tua architettura. Se mancano le dipendenze, le ricava con "winget download".
      4) Controlla la firma digitale dei file (devono essere firmati Microsoft).
      5) Rimuove il Lettore multimediale 11.x (Windows non permette il downgrade).
      6) Installa dipendenze e Groove.
      7) (Opzionale) Blocca gli aggiornamenti automatici dello Store.
      8) Se trova un file settings.dat (cartella dello script, Download, Desktop, Documenti)
         lo copia in %LOCALAPPDATA%\Packages\Microsoft.ZuneMusic_8wekyb3d8bbwe\Settings\
         (chiude l'app, fa un backup del file esistente, elimina i vecchi file .LOG1/.LOG2).

    NOTA: non e' garantito che esistano ancora versioni 10.x scaricabili. Se non ne trova,
    lo script si ferma senza toccare nulla (a meno di usare -AllowLatest).

.PARAMETER BlockStoreUpdates
    Disattiva il download automatico degli aggiornamenti dallo Store (vale per TUTTE le app).

.PARAMETER AllowLatest
    Se non trova nessun Groove 10.x, installa l'ultima versione disponibile (Lettore multimediale).

.PARAMETER PackagePath
    Facoltativo: percorso di un pacchetto Groove 10.x gia' scaricato.

.PARAMETER KeepFiles
    Non cancella i file scaricati alla fine (cartella %TEMP%\GrooveInstall).

.PARAMETER SettingsPath
    Facoltativo: percorso di un file settings.dat oppure di una cartella in cui cercarlo.

.PARAMETER OnlySettings
    Salta l'installazione e copia soltanto il file settings.dat (l'app deve essere gia' installata).
#>

[CmdletBinding()]
param(
    [switch]$BlockStoreUpdates,
    [switch]$AllowLatest,
    [string]$PackagePath,
    [switch]$KeepFiles,
    [string]$SettingsPath,
    [switch]$OnlySettings
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProductId = '9WZDNCRFJ3PT'
$WorkDir   = Join-Path $env:TEMP 'GrooveInstall'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($env:GROOVE_BAT_DIR) { $env:GROOVE_BAT_DIR.TrimEnd('\') } else { (Get-Location).Path }

# ---------------------------------------------------------------
# Funzioni di supporto
# ---------------------------------------------------------------
function Write-Step($m) { Write-Host "[*] $m"  -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[!] $m"  -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[X] $m"  -ForegroundColor Red }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Zune {
    Get-AppxPackage -Name 'Microsoft.ZuneMusic' -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
}

function Show-Status {
    $pkg = Get-Zune
    if ($null -eq $pkg) { Write-Warn "Microsoft.ZuneMusic NON e' installato."; return }
    if (([version]$pkg.Version).Major -ge 11) {
        Write-Warn "Installato: versione $($pkg.Version) -> e' il Lettore multimediale, NON il Groove originale."
    } else {
        Write-Ok "Installato: versione $($pkg.Version) -> Groove Music originale."
    }
}

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        'x86'   { 'x86' }
        default { 'x64' }
    }
}

# Trasforma un nome file tipo Microsoft.ZuneMusic_10.21.0_neutral_~_8wekyb3d8bbwe.msixbundle in oggetto
function Convert-NameToPkg {
    param([string]$Name, [string]$Url, [string]$Path)
    if ($Name -notmatch '\.(appx|msix|appxbundle|msixbundle)$') { return $null }
    $parts = $Name.Split('_')
    if ($parts.Count -lt 3) { return $null }
    $ver = $null
    try { $ver = [version]$parts[1] } catch { return $null }
    [pscustomobject]@{
        Name    = $Name
        Id      = $parts[0]
        Version = $ver
        Arch    = $parts[2]
        Url     = $Url
        Path    = $Path
    }
}

function Get-LocalPackages {
    param([string]$Dir, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $files = if ($Recurse) { Get-ChildItem -LiteralPath $Dir -File -Recurse -ErrorAction SilentlyContinue }
             else          { Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue }
    foreach ($f in $files) {
        if ($f.Name -like 'Microsoft.*') {
            $p = Convert-NameToPkg -Name $f.Name -Url $null -Path $f.FullName
            if ($p) { $p }
        }
    }
}

# Interroga store.rg-adguard.net (prima con intestazioni da browser, poi con curl.exe)
function Invoke-StoreQuery {
    param([string]$Id, [string]$Ring)
    $uri  = 'https://store.rg-adguard.net/api/GetFiles'
    $body = @{ type = 'ProductId'; url = $Id; ring = $Ring; lang = 'it-IT' }
    $hdr  = @{ Referer = 'https://store.rg-adguard.net/'; Origin = 'https://store.rg-adguard.net'; Accept = 'text/html,application/xhtml+xml,*/*' }
    $firstError = $null
    try {
        $r = Invoke-WebRequest -Uri $uri -Method Post -Body $body -UserAgent $UserAgent -Headers $hdr -UseBasicParsing -TimeoutSec 90
        return [string]$r.Content
    } catch {
        $firstError = $_.Exception.Message
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = $null
        try {
            $out = & curl.exe -s -L --max-time 90 -A $UserAgent -e 'https://store.rg-adguard.net/' `
                   -d 'type=ProductId' -d "url=$Id" -d "ring=$Ring" -d 'lang=it-IT' $uri 2>$null
        } catch { $out = $null }
        $ErrorActionPreference = $old
        if ($out) { return ($out -join "`n") }
    }
    throw $firstError
}

function Get-StoreLinks {
    param([string]$Id, [string]$Ring)
    $html = Invoke-StoreQuery -Id $Id -Ring $Ring
    $rx = [regex]'<a\s+href="(?<u>[^"]+)"[^>]*>(?<n>[^<]+)</a>'
    foreach ($m in $rx.Matches($html)) {
        $p = Convert-NameToPkg -Name $m.Groups['n'].Value.Trim() -Url $m.Groups['u'].Value.Replace('&amp;', '&') -Path $null
        if ($p) { $p }
    }
}

# Fallback: winget scarica dallo Store il pacchetto con le sue dipendenze
function Get-PackagesViaWinget {
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $w) { Write-Warn "winget non disponibile (installa 'App Installer' dallo Store)."; return @() }
    $d = Join-Path $WorkDir 'winget'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Write-Step "Provo con 'winget download' (puo' richiedere un minuto)..."
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & winget download --id $ProductId --source msstore --download-directory $d --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    } catch { }
    $ErrorActionPreference = $old
    return @(Get-LocalPackages -Dir $d -Recurse)
}

function Select-Best {
    param($Items)
    $Items | Sort-Object @{ Expression = { $_.Version }; Descending = $true }, @{ Expression = { [bool]$_.Path }; Descending = $true } |
        Select-Object -First 1
}

function Save-File {
    param([string]$Url, [string]$Dest)
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 900
    } catch {
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if (-not $curl) { throw }
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & curl.exe -s -L --max-time 900 -A $UserAgent -o $Dest $Url 2>$null
        $ErrorActionPreference = $old
    }
    if (-not (Test-Path -LiteralPath $Dest) -or (Get-Item -LiteralPath $Dest).Length -lt 1024) {
        throw "Download non riuscito: $Dest"
    }
}

# Restituisce il percorso locale del pacchetto (scaricandolo se serve)
function Resolve-Pkg {
    param($Pkg)
    if ($Pkg.Path) { return $Pkg.Path }
    $dest = Join-Path $WorkDir $Pkg.Name
    Write-Host "    scarico $($Pkg.Name)"
    Save-File -Url $Pkg.Url -Dest $dest
    return $dest
}

# $true = firmato Microsoft | $false = firmato da altri | $null = firma non verificabile
function Test-MsSignature {
    param([string]$Path)
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        if ($s.SignerCertificate) {
            if ($s.SignerCertificate.Subject -match 'Microsoft') { return $true } else { return $false }
        }
        return $null
    } catch { return $null }
}

function Assert-Signature {
    param([string]$Path)
    $r = Test-MsSignature -Path $Path
    $n = Split-Path $Path -Leaf
    if ($r -eq $false) { throw "Firma NON Microsoft per $n - interrompo per sicurezza." }
    if ($null -eq $r)  { Write-Warn "Firma non verificabile da PowerShell per $n (normale per alcuni bundle)." }
    else               { Write-Ok   "Firma Microsoft verificata: $n" }
}

function Set-StoreAutoUpdateBlock {
    $cmd = "New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force | Out-Null; " +
           "New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -PropertyType DWord -Value 2 -Force | Out-Null"
    if (Test-IsAdmin) {
        Invoke-Expression $cmd
    } else {
        Write-Step "Serve il permesso di amministratore solo per questo passaggio (conferma la finestra UAC)..."
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
    }
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload -ErrorAction SilentlyContinue).AutoDownload
    if ($v -eq 2) { Write-Ok "Aggiornamenti automatici dello Store disattivati (tutte le app)." }
    else          { Write-Warn "Non sono riuscito a disattivare gli aggiornamenti automatici." }
}

function Show-ManualHelp {
    Write-Host ""
    Write-Host "  COME PROCEDERE A MANO (30 secondi, il browser non viene bloccato):" -ForegroundColor White
    Write-Host "  1. Apri https://store.rg-adguard.net/ nel browser." -ForegroundColor Gray
    Write-Host "  2. Scegli 'ProductId', incolla $ProductId, scegli 'Slow' o 'RP', premi il tasto di conferma." -ForegroundColor Gray
    Write-Host "  3. Se nell'elenco vedi Microsoft.ZuneMusic con versione 10.x, scaricalo, insieme a" -ForegroundColor Gray
    Write-Host "     Microsoft.VCLibs, Microsoft.NET.Native.Framework/Runtime e Microsoft.UI.Xaml (versione $arch)." -ForegroundColor Gray
    Write-Host "  4. Metti tutti i file nella cartella dello script: $ScriptDir" -ForegroundColor Gray
    Write-Host "  5. Rilancia lo script: li trova e li installa da solo." -ForegroundColor Gray
    Write-Host "  Se nell'elenco NON c'e' nessuna 10.x, la versione originale non e' piu' scaricabile da fonti ufficiali." -ForegroundColor Gray
    Write-Host ""
}

# ---------------------------------------------------------------
# Copia di settings.dat nella cartella dati dell'app
# ---------------------------------------------------------------
function Test-RegHive {
    # I file settings.dat delle app UWP sono "hive" di registro: iniziano con la firma 'regf'
    param([string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $b = New-Object byte[] 4
            [void]$fs.Read($b, 0, 4)
        } finally { $fs.Dispose() }
        return ([Text.Encoding]::ASCII.GetString($b) -eq 'regf')
    } catch { return $false }
}

function Find-SettingsDat {
    param([string]$Hint)
    $skip  = Join-Path $env:LOCALAPPDATA 'Packages'
    $cands = @()

    if ($Hint) {
        if (Test-Path -LiteralPath $Hint -PathType Leaf) {
            return (Get-Item -LiteralPath $Hint)
        } elseif (Test-Path -LiteralPath $Hint -PathType Container) {
            $cands += @(Get-ChildItem -LiteralPath $Hint -Filter 'settings.dat' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)
        } else {
            Write-Warn "-SettingsPath non trovato: $Hint"
        }
    }

    if ($cands.Count -eq 0) {
        $dirs = @($ScriptDir,
                  (Join-Path $env:USERPROFILE 'Downloads'),
                  (Join-Path $env:USERPROFILE 'Desktop'),
                  (Join-Path $env:USERPROFILE 'Documents')) | Select-Object -Unique
        foreach ($d in $dirs) {
            if (Test-Path -LiteralPath $d) {
                $cands += @(Get-ChildItem -LiteralPath $d -Filter 'settings.dat' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)
            }
        }
    }

    # Non usare mai come sorgente un file che sta gia' dentro %LOCALAPPDATA%\Packages
    $cands = @($cands | Where-Object { $_.FullName -notlike "$skip*" })
    if ($cands.Count -eq 0) { return $null }

    # Preferisci quello accanto allo script, poi il piu' recente
    $best = $cands | Sort-Object @{ Expression = { $_.DirectoryName -eq $ScriptDir }; Descending = $true },
                                 @{ Expression = { $_.LastWriteTime }; Descending = $true } |
            Select-Object -First 1
    if ($cands.Count -gt 1) { Write-Warn "Trovati $($cands.Count) file settings.dat, uso: $($best.FullName)" }
    return $best
}

function Stop-ZuneProcesses {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -like '*\Microsoft.ZuneMusic_*' } catch { $false }
    })
    foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
    if ($procs.Count -gt 0) { Start-Sleep -Seconds 2 }
    return $procs.Count
}

# Restituisce $true se il file e' stato copiato, $false altrimenti (non genera mai errori bloccanti)
function Install-ZuneSettings {
    try {
        Write-Host ""
        Write-Step "Cerco il file settings.dat..."
        $src = Find-SettingsDat -Hint $SettingsPath
        if (-not $src) {
            Write-Warn "Nessun settings.dat trovato (cartella dello script, Download, Desktop, Documenti). Salto questo passaggio."
            return $false
        }
        Write-Ok "Trovato: $($src.FullName)"

        if (-not (Test-RegHive -Path $src.FullName)) {
            Write-Err "Il file non sembra un settings.dat valido (manca la firma 'regf'). Non lo copio, per non rovinare l'app."
            return $false
        }

        $pkg = Get-Zune
        if (-not $pkg) {
            Write-Warn "Microsoft.ZuneMusic non e' installato: non posso copiare le impostazioni."
            return $false
        }

        $family = 'Microsoft.ZuneMusic_8wekyb3d8bbwe'
        $target = Join-Path $env:LOCALAPPDATA "Packages\$family\Settings"

        Write-Step "Chiudo l'app (se aperta)..."
        [void](Stop-ZuneProcesses)

        # La cartella Settings esiste solo dopo il primo avvio: se manca, avvio l'app una volta
        if (-not (Test-Path -LiteralPath $target)) {
            Write-Step "Cartella Settings non ancora creata: avvio l'app una volta per generarla..."
            try {
                $m     = Get-AppxPackageManifest -Package $pkg.PackageFullName
                $appId = ($m.Package.Applications.Application | Select-Object -First 1).Id
                Start-Process "shell:AppsFolder\$family!$appId"
                for ($i = 0; $i -lt 30 -and -not (Test-Path -LiteralPath $target); $i++) { Start-Sleep -Seconds 1 }
                Start-Sleep -Seconds 3
                [void](Stop-ZuneProcesses)
            } catch {
                Write-Warn "Avvio automatico non riuscito: $($_.Exception.Message)"
            }
        }
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Write-Warn "Cartella creata manualmente: $target"
        }

        # Backup dei file esistenti e rimozione dei log di transazione (.LOG1/.LOG2) obsoleti
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        foreach ($n in 'settings.dat', 'settings.dat.LOG1', 'settings.dat.LOG2') {
            $f = Join-Path $target $n
            if (Test-Path -LiteralPath $f) {
                Copy-Item -LiteralPath $f -Destination ($f + ".bak-$stamp") -Force
                if ($n -ne 'settings.dat') { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            }
        }
        $dst = Join-Path $target 'settings.dat'
        if (Test-Path -LiteralPath $dst) { Write-Ok "Backup del file attuale creato (settings.dat.bak-$stamp)." }

        # Copia e verifica
        Copy-Item -LiteralPath $src.FullName -Destination $dst -Force
        try { Set-ItemProperty -LiteralPath $dst -Name IsReadOnly -Value $false } catch { }

        $h1 = (Get-FileHash -LiteralPath $src.FullName -Algorithm SHA256).Hash
        $h2 = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        if ($h1 -ne $h2) { throw "Verifica fallita: il file copiato e' diverso dall'originale." }

        Write-Ok "settings.dat copiato in: $target"
        return $true
    }
    catch {
        Write-Err "Copia di settings.dat non riuscita: $($_.Exception.Message)"
        Write-Warn "Chiudi Groove/Lettore multimediale (anche dalla barra delle applicazioni) e rilancia."
        return $false
    }
}

# ---------------------------------------------------------------
# Inizio
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== Installazione automatica di Groove Music (beta) ===" -ForegroundColor White

$os = [Environment]::OSVersion.Version
if ($os.Major -ne 10 -or $os.Build -ge 22000) {
    Write-Warn "Pensato per Windows 10 (rilevata build $($os.Build)). Procedo comunque."
}

$arch = Get-Arch
Write-Step "Architettura rilevata: $arch"
Write-Step "Stato attuale:"
Show-Status
Write-Host ""

if ($OnlySettings) {
    $okSettings = Install-ZuneSettings
    Write-Host ""
    if ($okSettings) { exit 0 } else { exit 1 }
}

$current = Get-Zune
if ($current -and ([version]$current.Version).Major -lt 11 -and -not $PackagePath) {
    Write-Ok "Groove originale gia' installato, non serve fare altro."
    if ($BlockStoreUpdates) { Set-StoreAutoUpdateBlock }
    [void](Install-ZuneSettings)
    exit 0
}

if ($AllowLatest -and $current -and ([version]$current.Version).Major -ge 11 -and -not $PackagePath) {
    Write-Ok "Il Lettore multimediale e' gia' installato, non serve reinstallarlo."
    [void](Install-ZuneSettings)
    exit 0
}

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$exitCode = 0

try {
    # -----------------------------------------------------------
    # 1) Raccogli i pacchetti disponibili (cartella locale + online)
    # -----------------------------------------------------------
    $pool = @()

    $local = @(Get-LocalPackages -Dir $ScriptDir)
    if ($local.Count -gt 0) {
        Write-Ok "Trovati $($local.Count) pacchetti nella cartella dello script."
        $pool += $local
    }

    $mainFile = $null
    if ($PackagePath) {
        if (-not (Test-Path -LiteralPath $PackagePath)) { throw "File non trovato: $PackagePath" }
        $mainFile = (Resolve-Path -LiteralPath $PackagePath).Path
        Write-Step "Uso il pacchetto indicato: $mainFile"
    }

    $haveGrooveLocal = @($pool | Where-Object { $_.Id -eq 'Microsoft.ZuneMusic' -and $_.Version.Major -eq 10 -and ($_.Arch -eq $arch -or $_.Arch -eq 'neutral') }).Count -gt 0
    $online = @()
    if (-not $mainFile -and -not $haveGrooveLocal) {
        Write-Step "Cerco i pacchetti online (rg-adguard)..."
        $anyOk = $false
        foreach ($ring in 'Retail', 'RP', 'WIS', 'WIF') {
            try {
                $found = @(Get-StoreLinks -Id $ProductId -Ring $ring)
                $anyOk = $true
                Write-Host "    ring $ring : $($found.Count) file"
                $online += $found
            } catch {
                Write-Warn "ring $ring non raggiungibile: $($_.Exception.Message)"
            }
        }
        if (-not $anyOk) { Write-Warn "Il servizio online non risponde (probabile blocco anti-bot)." }
        $pool += $online
    }

    # -----------------------------------------------------------
    # 2) Scegli il pacchetto principale
    # -----------------------------------------------------------
    $zuneAll = @($pool | Where-Object { $_.Id -eq 'Microsoft.ZuneMusic' } | Sort-Object Version -Descending)
    if ($zuneAll.Count -gt 0) {
        Write-Step "Versioni di Microsoft.ZuneMusic trovate:"
        foreach ($z in $zuneAll) { Write-Host "    $($z.Version)  [$($z.Arch)]" }
    } else {
        Write-Warn "Nessuna versione di Microsoft.ZuneMusic trovata nell'elenco."
    }
    $chosen = $null
    if (-not $mainFile) {
        $groove = Select-Best -Items @($pool | Where-Object { $_.Id -eq 'Microsoft.ZuneMusic' -and $_.Version.Major -eq 10 -and ($_.Arch -eq $arch -or $_.Arch -eq 'neutral') })
        if ($groove) {
            Write-Ok "Groove originale trovato: $($groove.Name)"
            $chosen = $groove
        } elseif ($AllowLatest) {
            Write-Warn "Nessun Groove 10.x trovato. -AllowLatest attivo: cerco l'ultima versione disponibile."
            $latest = Select-Best -Items @($pool | Where-Object { $_.Id -eq 'Microsoft.ZuneMusic' -and $_.Version.Major -ge 11 -and ($_.Arch -eq $arch -or $_.Arch -eq 'neutral') })
            if (-not $latest) {
                $pool += Get-PackagesViaWinget
                $latest = Select-Best -Items @($pool | Where-Object { $_.Id -eq 'Microsoft.ZuneMusic' -and $_.Version.Major -ge 11 -and ($_.Arch -eq $arch -or $_.Arch -eq 'neutral') })
            }
            if (-not $latest) { throw "Non sono riuscito a ottenere nessuna versione di Microsoft.ZuneMusic." }
            Write-Warn "Uso la versione $($latest.Version) (Lettore multimediale)."
            $chosen = $latest
        } else {
            Write-Err "Nessun Groove originale (10.x) disponibile. Le versioni 1.x/2.x/3.x sono di epoche precedenti e non vanno bene. Non ho modificato nulla."
            Show-ManualHelp
            $exitCode = 2
            throw [System.OperationCanceledException]::new('stop')
        }
        $mainFile = Resolve-Pkg -Pkg $chosen
    }

    # -----------------------------------------------------------
    # 3) Dipendenze per la tua architettura
    # -----------------------------------------------------------
    function Get-DepList {
        param($Source)
        $c = @($Source | Where-Object {
            $_.Id -match '^Microsoft\.(VCLibs|NET\.Native|UI\.Xaml)' -and
            ($_.Arch -eq $arch -or $_.Arch -eq 'neutral')
        })
        $c | Group-Object Id | ForEach-Object { Select-Best -Items $_.Group }
    }

    $depList = @(Get-DepList -Source $pool)
    if ($depList.Count -eq 0) {
        Write-Warn "Nessuna dipendenza trovata. Provo a ricavarla con winget..."
        $pool += Get-PackagesViaWinget
        $depList = @(Get-DepList -Source $pool)
    }

    $depFiles = @()
    if ($depList.Count -eq 0) {
        Write-Warn "Nessuna dipendenza disponibile: provo comunque a installare il pacchetto."
    } else {
        Write-Step "Preparo $($depList.Count) dipendenze..."
        foreach ($d in $depList) { $depFiles += (Resolve-Pkg -Pkg $d) }
        Write-Ok "Dipendenze pronte."
    }

    # -----------------------------------------------------------
    # 4) Verifica firme digitali
    # -----------------------------------------------------------
    Write-Step "Verifico le firme digitali..."
    foreach ($f in @($mainFile) + $depFiles) { Assert-Signature -Path $f }

    # -----------------------------------------------------------
    # 5) Rimuovi la versione 11.x (niente downgrade possibile)
    # -----------------------------------------------------------
    $existing = Get-Zune
    if ($existing -and ([version]$existing.Version).Major -ge 11) {
        Write-Step "Rimuovo la versione attuale ($($existing.Version)) per permettere il downgrade..."
        Remove-AppxPackage -Package $existing.PackageFullName
        Write-Ok "Versione precedente rimossa."
    }

    # -----------------------------------------------------------
    # 6) Installa dipendenze (una alla volta) e poi Groove
    # -----------------------------------------------------------
    foreach ($d in $depFiles) {
        $n = Split-Path $d -Leaf
        try {
            Add-AppxPackage -Path $d
            Write-Ok "Dipendenza installata: $n"
        } catch {
            Write-Host "    $n : gia' presente o non necessaria ($($_.Exception.Message.Split("`n")[0]))" -ForegroundColor DarkGray
        }
    }

    Write-Step "Installo il pacchetto principale..."
    Add-AppxPackage -Path $mainFile
    Write-Ok "Installazione completata."

    # -----------------------------------------------------------
    # 7) Blocco aggiornamenti Store (opzionale)
    # -----------------------------------------------------------
    Write-Host ""
    if ($BlockStoreUpdates) { Set-StoreAutoUpdateBlock }
    else { Write-Warn "Senza -BlockStoreUpdates lo Store potrebbe riaggiornare Groove a Lettore multimediale." }

    # -----------------------------------------------------------
    # 8) Copia di settings.dat (se presente)
    # -----------------------------------------------------------
    [void](Install-ZuneSettings)
}
catch [System.OperationCanceledException] {
    # uscita pianificata (nessun pacchetto disponibile): messaggio gia' mostrato
}
catch {
    Write-Host ""
    Write-Err "Errore: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    if (-not $KeepFiles -and (Test-Path -LiteralPath $WorkDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Show-Status
exit $exitCode
