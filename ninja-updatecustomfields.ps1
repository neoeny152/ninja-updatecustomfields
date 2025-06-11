# =======================
# CONFIGURATION SECTION
# =======================
 
# Path to your CSV
$CSV_PATH     = "C:\path\customfieldupdate.csv"
 
# NinjaOne API info
$API_BASE_URL  = "https://us2.ninjarmm.com"
$CLIENT_ID     = ""
$CLIENT_SECRET = ""
$REDIRECT_URI  = "https://localhost"
 
# Log file
$LOG_PATH      = "C:\admin\ninjaone_mass_update_log.txt"
 
# =======================
# UTILITY FUNCTIONS
# =======================
 
function Log-Message {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $Message" | Out-File -FilePath $LOG_PATH -Append
}
 
function Debug-Message {
    param([string]$Message)
    Write-Host "[DEBUG] $Message" -ForegroundColor Yellow
    Log-Message "[DEBUG] $Message"
}
 
function Get-AccessToken {
    try {
        Debug-Message "Requesting access token..."
        $uri  = "$API_BASE_URL/oauth/token"
        $hdr  = @{ accept="application/json"; "Content-Type"="application/x-www-form-urlencoded" }
        $body = @{
            redirect_uri  = $REDIRECT_URI
            grant_type    = "client_credentials"
            client_id     = $CLIENT_ID
            client_secret = $CLIENT_SECRET
            scope         = "monitoring management"
        }
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $hdr -Body $body
        Debug-Message "Access token acquired."
        return $resp.access_token
    }
    catch {
        Log-Message "ERROR: Failed to retrieve access token: $_"
        throw "Unable to retrieve access token."
    }
}
 
# In-memory cache for Name → NodeID
$NodeIdCache = @{}
 
function Get-NodeId {
    param(
        [string]$DeviceName,
        [string]$AccessToken
    )
 
    $key = $DeviceName.ToLower()
    if ($NodeIdCache.ContainsKey($key)) {
        Debug-Message "Cache hit: '$DeviceName' → NodeID $($NodeIdCache[$key])"
        return $NodeIdCache[$key]
    }
 
    Debug-Message "Looking up NodeID for '$DeviceName'..."
    $encoded  = [System.Web.HttpUtility]::UrlEncode($DeviceName)
    $uri      = "$API_BASE_URL/api/v2/devices?searchTerm=$encoded&take=100"
    Debug-Message "GET $uri"
 
    $headers  = @{ Authorization = "Bearer $AccessToken" }
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
 
    # **IMPORTANT**: response is a bare array, not under .value or .items
    $list = if ($response -is [System.Array]) { $response } else { @() }
 
    if (-not $list.Count) {
        Debug-Message "→ No matches found."
        return $null
    }
 
    # exact match (case‐insensitive)
    $exact = $list | Where-Object { $_.systemName -and $_.systemName.ToLower() -eq $key } | Select-Object -First 1
    if ($exact) {
        Debug-Message "→ Exact match: '$($exact.systemName)' (ID $($exact.id))"
        $NodeIdCache[$key] = $exact.id
        return $exact.id
    }
 
    # fallback: first entry
    $first = $list[0]
    Debug-Message "→ No exact match; using first: '$($first.systemName)' (ID $($first.id))"
    $NodeIdCache[$key] = $first.id
    return $first.id
}
 
function Update-CustomField {
    param(
        [string]$NodeId,
        [string]$CustomFieldName,
        [string]$FieldValue,
        [string]$AccessToken
    )
    try {
        $uri      = "$API_BASE_URL/api/v2/device/$NodeId/custom-fields"
        $hdr      = @{ Authorization = "Bearer $AccessToken" }
        $bodyHash = @{ $CustomFieldName = $FieldValue }
        $body     = $bodyHash | ConvertTo-Json -Depth 8
 
        Debug-Message "PATCH $uri"
        Debug-Message "Body: $body"
        Invoke-RestMethod -Uri $uri -Method Patch -Headers $hdr -Body $body -ContentType "application/json"
        Debug-Message "→ Field '$CustomFieldName' set to '$FieldValue' on NodeID $NodeId."
    }
    catch {
        Debug-Message ("ERROR updating '{0}' on NodeID {1}: {2}" -f $CustomFieldName, $NodeId, $_)
    }
}
 
 
# =======================
# MAIN SCRIPT
# =======================
 
try {
    # Ensure log directory exists
    $logDir = Split-Path $LOG_PATH
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
 
    Log-Message "=== Starting mass update ==="
 
    if (-not (Test-Path $CSV_PATH)) {
        throw "CSV file not found: $CSV_PATH"
    }
 
    # 1) Acquire token
    $token = Get-AccessToken
 
    # 2) Import & normalize CSV
    $rows = Import-Csv -Path $CSV_PATH
    Debug-Message ("Imported {0} row(s)." -f $rows.Count)
 
    foreach ($row in $rows) {
        foreach ($prop in $row.PSObject.Properties.Name) {
            if ($prop -match '^(?i)device\s*name$') {
                $val = $row.$prop
                $row.PSObject.Properties.Remove($prop)
                $row | Add-Member -NotePropertyName 'DeviceName' -NotePropertyValue $val
                Debug-Message ("Normalized '{0}' → 'DeviceName' (='{1}')" -f $prop, $val)
            }
            elseif ($prop -match '^(?i)node\s*id$') {
                $val = $row.$prop
                $row.PSObject.Properties.Remove($prop)
                $row | Add-Member -NotePropertyName 'NodeID' -NotePropertyValue $val
                Debug-Message ("Normalized '{0}' → 'NodeID' (='{1}')" -f $prop, $val)
            }
        }
    }
 
    # 3) Process each row
    $i = 0
    foreach ($row in $rows) {
        $i++
        Debug-Message ("---- Row {0} ----" -f $i)
 
        if ($row.PSObject.Properties.Name -contains 'NodeID' -and $row.NodeID) {
            $nid = $row.NodeID
            Debug-Message ("Using provided NodeID: {0}" -f $nid)
        }
        elseif ($row.DeviceName) {
            $nid = Get-NodeId -DeviceName $row.DeviceName -AccessToken $token
            if (-not $nid) {
                Debug-Message ("No NodeID found for '{0}'; skipping." -f $row.DeviceName)
                continue
            }
        }
        else {
            Debug-Message "Neither NodeID nor DeviceName—skipping."
            continue
        }
 
        # Identify custom fields to update
        $fields = $row.PSObject.Properties |
            Where-Object { $_.Name -notin @('NodeID','DeviceName') -and $_.Value }
        Debug-Message ("Found {0} custom field(s)." -f $fields.Count)
 
        if (-not $fields) {
            Debug-Message ("Nothing to update for NodeID {0}." -f $nid)
            continue
        }
 
        foreach ($cf in $fields) {
            Debug-Message ("Updating '{0}' = '{1}'" -f $cf.Name, $cf.Value)
            Update-CustomField -NodeId        $nid `
                               -CustomFieldName $cf.Name `
                               -FieldValue      $cf.Value `
                               -AccessToken     $token
        }
    }
 
    Log-Message "=== Mass update completed ==="
    Write-Host "Done. Check debug above and $LOG_PATH" -ForegroundColor Green
}
catch {
    Log-Message ("FATAL: {0}" -f $_)
    Write-Host ("Fatal error: {0}" -f $_) -ForegroundColor Red
    throw
}