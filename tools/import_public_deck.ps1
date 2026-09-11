<#
.SYNOPSIS
    Trae un mazo PUBLICO de ShadowForge (iterva.pythonanywhere.com) y lo
    guarda como preset local del juego (preset-<Slug>.json), en el mismo
    lugar de donde DeckSelector.gd los lee.

.DESCRIPTION
    Uso pensado (2026-09-03, a pedido del usuario — antes esto se hacia a
    mano cada vez, buscando el endpoint de nuevo en cada sesion): cuando
    quieras reemplazar/actualizar uno de los mazos preset del selector
    (Guerrero, Caballero, etc.) por un mazo real publicado por alguien en
    ShadowForge, corres este script con el ID del mazo (visible en la URL
    del sitio, ej. shadow-forge-deck.vercel.app/decks/128) y el arquetipo
    al que corresponde.

    El endpoint /api/decks/public/ (SIN el prefijo 'external/' que tienen
    el resto de los endpoints de esta API) se encontro bajando los bundles
    JS compilados del frontend real (shadow-forge-deck.vercel.app) y
    grepeando por rutas — mismo truco que ya se uso para encontrar
    iterva.pythonanywhere.com la primera vez (ver el comentario de cabecera
    de ExternalApiClient.gd). Solo lectura confirmada — no hay endpoint de
    escritura conocido para editar mazos publicos de otros usuarios.

.PARAMETER DeckId
    ID numerico del mazo publico en ShadowForge (ej. 128).

.PARAMETER Slug
    Arquetipo/slug destino SIN el prefijo 'preset-' (ej. "guerrero" escribe
    preset-guerrero.json, pisando el que exista).

.PARAMETER Archetype
    Texto para el campo "arquetipo" del preset. Por defecto, Slug con la
    primera letra en mayuscula.

.PARAMETER NameSuffix
    Sufijo que se agrega al nombre real del mazo para el campo "nombre"
    (por defecto " (publico)", mismo criterio que ya tenian los presets
    existentes antes de este script).

.EXAMPLE
    .\import_public_deck.ps1 -DeckId 128 -Slug guerrero

.EXAMPLE
    .\import_public_deck.ps1 -DeckId 51 -Slug guerrero -Archetype "Guerrero" -NameSuffix " (backup)"
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$DeckId,
    [Parameter(Mandatory = $true)]
    [string]$Slug,
    [string]$Archetype = "",
    [string]$NameSuffix = " (publico)",
    [string]$Formato = "imp"
)

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$credFile = Join-Path $here "shadowforge_credentials.local.ps1"
if (-not (Test-Path $credFile)) {
    Write-Error "Falta $credFile. Copia shadowforge_credentials.example.ps1 con ese nombre y completa usuario/contrasena."
    exit 1
}
. $credFile

$apiBase = "https://iterva.pythonanywhere.com/api"
$decksDir = Join-Path $env:APPDATA "Godot\app_userdata\Mitos y Leyendas\decks"
if (-not (Test-Path $decksDir)) {
    Write-Error "No se encontro la carpeta de mazos locales del juego en: $decksDir"
    exit 1
}

# Ver reload_card.ps1 (mismo motivo): Invoke-RestMethod no decodifica bien
# UTF-8 cuando el servidor no declara el charset -- se lee el stream de
# bytes crudo y se decodifica explicito.
function Invoke-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = "Get",
        [hashtable]$Headers = @{},
        [string]$Body = $null,
        [string]$ContentType = "application/json"
    )
    $params = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true; Headers = $Headers }
    if ($Body) {
        $params.Body = $Body
        $params.ContentType = $ContentType
    }
    $resp = Invoke-WebRequest @params
    $bytes = $resp.RawContentStream.ToArray()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $text | ConvertFrom-Json
}

Write-Host "Iniciando sesion en ShadowForge..."
$body = @{ username = $ShadowForgeUser; password = $ShadowForgePass } | ConvertTo-Json
$tokenResp = Invoke-Utf8Json -Uri "$apiBase/external/token/" -Method Post -Body $body
$accessToken = $tokenResp.access

Write-Host "Bajando mazo publico $DeckId..."
$deck = Invoke-Utf8Json -Uri "$apiBase/decks/public/$DeckId/" -Headers @{ Authorization = "Bearer $accessToken" }

if (-not $deck.entries -or $deck.entries.Count -eq 0) {
    Write-Error "El mazo $DeckId no tiene 'entries' (¿ID equivocado, o no es publico?)."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Archetype)) {
    $Archetype = $Slug.Substring(0,1).ToUpper() + $Slug.Substring(1)
}

$entries = @()
$total = 0
foreach ($e in $deck.entries) {
    if (-not $e.card_detail.myl_id -or -not $e.quantity) { continue }
    $entries += [ordered]@{ myl_id = $e.card_detail.myl_id; quantity = $e.quantity }
    $total += $e.quantity
}

$preset = [ordered]@{
    slug      = "preset-$Slug"
    nombre    = "$($deck.name)$NameSuffix"
    arquetipo = $Archetype
    formato   = $Formato
    entries   = $entries
}

$outPath = Join-Path $decksDir "preset-$Slug.json"
# Set-Content -Encoding utf8 en PowerShell 5.1 agrega un BOM al inicio del
# archivo (2026-09-03, detectado comparando contra un preset escrito sin
# BOM) -- se escribe directo con .NET para evitarlo, sin depender de si
# Godot lo tolera bien o no.
$jsonText = $preset | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($outPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Mazo publico '$($deck.name)' (owner: $($deck.owner_username)) -> $outPath"
Write-Host "$($entries.Count) entradas, $total cartas totales."
Write-Host "Reinicia el juego para que el selector de mazos tome el cambio."
