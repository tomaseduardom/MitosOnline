<#
.SYNOPSIS
    Recarga una o mas cartas puntuales desde la API real de ShadowForge
    (iterva.pythonanywhere.com) hacia el cache local que usa el juego
    (CardDatabase.gd), sin tocar el resto del cache.

.DESCRIPTION
    Uso pensado (2026-08-26): cuando una carta tiene datos viejos o mal
    cargados en el cache local (ej. Bernardo O'Higgins con una habilidad
    inventada), le pedis al dueno de ShadowForge que la corrija y despues
    corres este script para traer SOLO esa carta actualizada, sin volver a
    bajar las ~2400 cartas ni tocar nada mas del cache.

.PARAMETER CardName
    Texto a buscar en el nombre de la carta (no distingue mayusculas,
    coincidencia parcial). Puede matchear mas de una carta (ej. varias
    ediciones de "Bernardo O'Higgins") — se actualizan todas las que matcheen.

.PARAMETER Format
    Formato/temporada a consultar en la API (default "imp" = Imperio).

.EXAMPLE
    .\reload_card.ps1 -CardName "bernardo ohiggins"

.EXAMPLE
    .\reload_card.ps1 -CardName "signo amarillo" -Format imp
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$CardName,
    [string]$Format = "imp"
)

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$credFile = Join-Path $here "shadowforge_credentials.local.ps1"
if (-not (Test-Path $credFile)) {
    Write-Error "Falta $credFile. Copia shadowforge_credentials.example.ps1 con ese nombre y completa usuario/contrasena."
    exit 1
}
. $credFile

$apiBase = "https://iterva.pythonanywhere.com/api/external"
$cacheFile = Join-Path $env:APPDATA "Godot\app_userdata\Mitos y Leyendas\card_cache\cards.json"

if (-not (Test-Path $cacheFile)) {
    Write-Error "No se encontro el cache local del juego en: $cacheFile"
    exit 1
}

# Invoke-RestMethod en PowerShell 5.1 no detecta bien el charset de la
# respuesta cuando el servidor no lo declara en el header Content-Type, y
# decodifica el body con la codepage por defecto del sistema en vez de
# UTF-8 -- los bytes UTF-8 de tildes/enies quedan mal interpretados
# (mojibake tipo "ahÃ­" en vez de "ahí", "Ã©" en vez de "é"), corrompiendo
# habilidad/edicion de cualquier carta con acentos (2026-08-29, detectado
# con Tesoro de los Cesares y Don de Amma). Se lee el stream de bytes crudo
# de la respuesta y se decodifica explicitamente como UTF-8 antes de
# parsear el JSON.
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
$tokenResp = Invoke-Utf8Json -Uri "$apiBase/token/" -Method Post -Body $body
$accessToken = $tokenResp.access

Write-Host "Bajando cartas del formato '$Format'..."
$cardsResp = Invoke-Utf8Json -Uri "$apiBase/cards/$Format/" -Headers @{ Authorization = "Bearer $accessToken" }

$needle = [regex]::Escape($CardName)
$matches = $cardsResp.cards | Where-Object { $_.name -match $needle }

if (-not $matches -or $matches.Count -eq 0) {
    Write-Warning "No se encontro ninguna carta cuyo nombre contenga '$CardName' en el formato '$Format'."
    exit 1
}

# Constants.CardType (Constants.gd): ORO=0, ALIADO=1, ARMA=2, TALISMAN=3, TOTEM=4
$typeMap = @{
    "oro" = 0; "aliado" = 1; "arma" = 2; "talisman" = 3; "talismán" = 3; "totem" = 4; "tótem" = 4
}
# Constants.Keyword (Constants.gd), en el mismo orden del enum
$keywordMap = [ordered]@{
    "furia" = 0; "imbloqueable" = 1; "indestructible" = 2; "indesterrable" = 3
    "única" = 4; "unica" = 4; "exhumar" = 5; "errante" = 6; "retador" = 7
}

$cache = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
$cacheList = [System.Collections.Generic.List[object]]::new()
foreach ($c in $cache) { $cacheList.Add($c) }

$updatedCount = 0
foreach ($m in $matches) {
    $abilityText = ""
    if ($m.ability) { $abilityText = $m.ability }
    $lowerAbility = $abilityText.ToLower()

    $keywords = New-Object System.Collections.ArrayList
    foreach ($kw in $keywordMap.Keys) {
        if ($lowerAbility.Contains($kw) -and -not $keywords.Contains($keywordMap[$kw])) {
            [void]$keywords.Add($keywordMap[$kw])
        }
    }

    $typeKey = "aliado"
    if ($m.type) { $typeKey = $m.type.ToString().ToLower() }
    $tipo = 1
    if ($typeMap.ContainsKey($typeKey)) { $tipo = $typeMap[$typeKey] }

    $coste = 0
    if ($null -ne $m.cost -and $m.cost -ne "") { $coste = [int]$m.cost }
    $fuerza = 0
    if ($null -ne $m.damage -and $m.damage -ne "") { $fuerza = [int]$m.damage }

    # El juego espera siempre un String en estos campos (aunque sea vacio) —
    # la API a veces trae null (ej. Infernum Vox con "race": null), y
    # escribir null literal ahi rompia la carga con "Trying to assign value
    # of type 'Nil' to a variable of type 'String'" (2026-08-26).
    $raza = ""
    if ($null -ne $m.race) { $raza = $m.race }
    $edicion = ""
    if ($null -ne $m.edition_title) { $edicion = $m.edition_title }
    $frecuencia = ""
    if ($null -ne $m.rarity) { $frecuencia = $m.rarity }
    $imagen = ""
    if ($null -ne $m.image_url) { $imagen = $m.image_url }

    $newCard = [ordered]@{
        id          = $m.myl_id
        uuid        = $m.myl_id
        nombre      = $m.name
        tipo        = $tipo
        coste       = $coste
        fuerza      = $fuerza
        habilidad   = $abilityText
        raza        = $raza
        edicion     = $edicion
        frecuencia  = $frecuencia
        imagen      = $imagen
        keywords    = @($keywords)
        texto_epico = ""
    }

    $idx = -1
    for ($i = 0; $i -lt $cacheList.Count; $i++) {
        if ($cacheList[$i].id -eq $m.myl_id -or $cacheList[$i].uuid -eq $m.myl_id) { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $cacheList[$idx] = [PSCustomObject]$newCard
        Write-Host "  Actualizada: $($m.name)  [id $($m.myl_id), $($m.edition_title)]"
    } else {
        $cacheList.Add([PSCustomObject]$newCard)
        Write-Host "  Agregada (no estaba en el cache): $($m.name)  [id $($m.myl_id), $($m.edition_title)]"
    }
    $updatedCount++
}

$cacheList | ConvertTo-Json -Depth 6 | Set-Content -Path $cacheFile -Encoding utf8

Write-Host ""
Write-Host "$updatedCount carta(s) actualizadas en:"
Write-Host "  $cacheFile"
Write-Host "Reinicia el juego (o recarga el cache) para que tome los cambios."
