param(
    [Parameter(Mandatory=$true)]
    [string]$TargetUrl,

    [Parameter(Mandatory=$false)]
    [string]$DownloadFolder = "SiteData",

    [Parameter(Mandatory=$false)]
    [int]$MaxDepth = 2
)

function Get-WebContent
{
    param([string]$Url)

    try
    {
        $webRequest = [System.Net.WebRequest]::Create($Url)
        $webRequest.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        $webRequest.Timeout = 30000
        $response = $webRequest.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $content = $reader.ReadToEnd()
        $reader.Close()
        $stream.Close()
        $response.Close()
        return $content
    }
    catch
    {
        return $null
    }
}

function Download-File
{
    param([string]$Url, [string]$LocalPath)

    try
    {
        $directory = Split-Path $LocalPath -Parent
        if (-not (Test-Path $directory))
        {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0")
        $webClient.DownloadFile($Url, $LocalPath)
        $webClient.Dispose()
        return $true
    }
    catch
    {
        return $false
    }
}

function Normalize-Url
{
    param([string]$Url, [string]$BaseUrl)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    $Url = $Url.Trim()

    if ($Url -match "^(javascript|mailto|tel|data|#)")
    {
        return $null
    }

    if ($Url -match "^https?://")
    {
        $hashIndex = $Url.IndexOf("#")
        if ($hashIndex -gt 0) { $Url = $Url.Substring(0, $hashIndex) }
        $qIndex = $Url.IndexOf("?")
        if ($qIndex -gt 0) { $Url = $Url.Substring(0, $qIndex) }
        return $Url
    }

    if ($Url -match "^//")
    {
        $uri = [System.Uri]$BaseUrl
        return "$($uri.Scheme):$Url"
    }

    if ($Url -match "^/")
    {
        $uri = [System.Uri]$BaseUrl
        return "$($uri.Scheme)://$($uri.Host)$Url"
    }

    $uri = [System.Uri]$BaseUrl
    $basePath = [System.IO.Path]::GetDirectoryName($uri.LocalPath)
    if ($basePath -eq "\") { $basePath = "" }
    $relativePath = "$basePath/$Url".Replace("//", "/")
    return "$($uri.Scheme)://$($uri.Host)$relativePath"
}

function Get-LocalPath
{
    param([string]$Url, [string]$BaseHost)

    $uri = [System.Uri]$Url
    $localPath = $uri.LocalPath

    if ([string]::IsNullOrWhiteSpace($localPath) -or $localPath -eq "/")
    {
        $localPath = "/index.html"
    }

    $extension = [System.IO.Path]::GetExtension($localPath)
    if ([string]::IsNullOrWhiteSpace($extension))
    {
        if ($localPath.EndsWith("/"))
        {
            $localPath = $localPath + "index.html"
        }
        else
        {
            $localPath = $localPath + ".html"
        }
    }

    $invalidChars = '[\\/:*?"<>|]'
    $localPath = $localPath -replace $invalidChars, "_"

    if ($localPath.StartsWith("/"))
    {
        $localPath = $localPath.Substring(1)
    }

    return $localPath
}

function Extract-Urls
{
    param([string]$Content, [string]$BaseUrl, [string]$BaseHost)

    $urls = @()
    $patterns = @(
        'href\s*=\s*["'']([^"''#]+)',
        'src\s*=\s*["'']([^"''#]+)',
        'data\s*=\s*["'']([^"''#]+\.(css|js|xml|json))'
    )

    foreach ($pattern in $patterns)
    {
        $matches = [System.Text.RegularExpressions.Regex]::Matches($Content, $pattern, "IgnoreCase")
        foreach ($match in $matches)
        {
            if ($match.Success -and $match.Groups[1].Value)
            {
                $foundUrl = $match.Groups[1].Value
                $normalized = Normalize-Url -Url $foundUrl -BaseUrl $BaseUrl
                if ($normalized -and $normalized -match "^https?://")
                {
                    $uri = [System.Uri]$normalized
                    if ($uri.Host -eq $BaseHost)
                    {
                        $urls += $normalized
                    }
                }
            }
        }
    }

    return $urls | Select-Object -Unique
}

function Should-Download
{
    param([string]$Url)

    $extension = [System.IO.Path]::GetExtension($Url).ToLower()
    if ([string]::IsNullOrWhiteSpace($extension)) { return $true }

    $allowed = @(".html", ".htm", ".css", ".js", ".json", ".xml", ".txt",
                 ".jpg", ".jpeg", ".png", ".gif", ".svg", ".webp",
                 ".pdf", ".ico", ".woff", ".woff2", ".ttf")

    return $extension -in $allowed
}

$script:processedUrls = @{}
$script:downloadedFiles = @()
$script:totalUrls = 0

function Process-Url
{
    param([string]$Url, [string]$BaseUrl, [string]$BaseHost, [string]$DownloadPath, [int]$CurrentDepth, [int]$MaxDepth)

    if ($CurrentDepth -gt $MaxDepth) { return }

    if ($script:processedUrls.ContainsKey($Url)) { return }

    $script:processedUrls[$Url] = $true
    $script:totalUrls++

    Write-Progress -Activity "Downloading website" -Status "Processing: $Url" -PercentComplete (($script:processedUrls.Count % 100))

    $localFile = Get-LocalPath -Url $Url -BaseHost $BaseHost
    $fullPath = Join-Path $DownloadPath $localFile

    if (Should-Download -Url $Url)
    {
        if (Download-File -Url $Url -LocalPath $fullPath)
        {
            $script:downloadedFiles += $fullPath
            Write-Host "Downloaded: $Url" -ForegroundColor Green
        }
        else
        {
            Write-Host "Failed: $Url" -ForegroundColor Red
        }
    }

    $extension = [System.IO.Path]::GetExtension($Url).ToLower()
    if ($extension -in @(".html", ".htm", ".xml", ".xhtml"))
    {
        if (Test-Path $fullPath)
        {
            $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
            if ($content)
            {
                $newUrls = Extract-Urls -Content $content -BaseUrl $Url -BaseHost $BaseHost
                foreach ($nextUrl in $newUrls)
                {
                    Process-Url -Url $nextUrl -BaseUrl $BaseUrl -BaseHost $BaseHost -DownloadPath $DownloadPath -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth
                }
            }
        }
    }
}

function Get-FullSite
{
    param([string]$Url, [string]$DownloadPath, [int]$Depth)

    if (-not (Test-Path $DownloadPath))
    {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $uri = [System.Uri]$Url
    $baseHost = $uri.Host
    $baseUrl = "$($uri.Scheme)://$($uri.Host)"

    Write-Host "Starting download from: $Url" -ForegroundColor Yellow
    Write-Host "Target host: $baseHost" -ForegroundColor Cyan
    Write-Host "Download folder: $DownloadPath" -ForegroundColor Cyan
    Write-Host "Max depth: $Depth" -ForegroundColor Cyan
    Write-Host ""

    $startTime = Get-Date

    Process-Url -Url $Url -BaseUrl $baseUrl -BaseHost $baseHost -DownloadPath $DownloadPath -CurrentDepth 0 -MaxDepth $Depth

    $endTime = Get-Date
    $duration = $endTime - $startTime

    Write-Host ""
    Write-Host "Download completed" -ForegroundColor Green
    Write-Host "Processed URLs: $($script:processedUrls.Count)" -ForegroundColor Yellow
    Write-Host "Downloaded files: $($script:downloadedFiles.Count)" -ForegroundColor Green
    Write-Host "Total time: $($duration.TotalSeconds) seconds" -ForegroundColor Cyan
}

function Get-PageInfo
{
    param([string]$Url)

    try
    {
        $webRequest = [System.Net.WebRequest]::Create($Url)
        $webRequest.UserAgent = "Mozilla/5.0"
        $webRequest.Timeout = 10000
        $response = $webRequest.GetResponse()

        Write-Host "Website Information" -ForegroundColor Magenta
        Write-Host "URL: $Url" -ForegroundColor Cyan
        Write-Host "Status Code: $($response.StatusCode)" -ForegroundColor Yellow
        Write-Host "Content Type: $($response.ContentType)" -ForegroundColor Green
        Write-Host "Content Length: $($response.ContentLength) bytes" -ForegroundColor Green

        $response.Close()
    }
    catch
    {
        Write-Host "Error getting info: $_" -ForegroundColor Red
    }
}

function Get-SinglePage
{
    param([string]$Url, [string]$OutputFile)

    $content = Get-WebContent -Url $Url

    if ($content)
    {
        $content | Out-File -FilePath $OutputFile -Encoding UTF8
        $fileSize = (Get-Item $OutputFile).Length
        Write-Host "Content saved to: $OutputFile" -ForegroundColor Green
        Write-Host "File size: $([math]::Round($fileSize / 1KB, 2)) KB" -ForegroundColor Cyan
    }
    else
    {
        Write-Host "Failed to retrieve content" -ForegroundColor Red
    }
}

function Show-Menu
{
    Clear-Host
    Write-Host "====================================" -ForegroundColor White
    Write-Host "    Website Data Downloader Tool    " -ForegroundColor White
    Write-Host "====================================" -ForegroundColor White
    Write-Host ""
    Write-Host "1. Download single page" -ForegroundColor Yellow
    Write-Host "2. Get website information only" -ForegroundColor Yellow
    Write-Host "3. Download full website with assets" -ForegroundColor Yellow
    Write-Host "4. Exit" -ForegroundColor Red
    Write-Host ""
    Write-Host "====================================" -ForegroundColor White
}

do
{
    Show-Menu
    $choice = Read-Host "Select option"

    switch ($choice)
    {
        "1"
        {
            $url = Read-Host "Enter URL"
            $outputFile = Read-Host "Output filename"
            if ([string]::IsNullOrWhiteSpace($outputFile))
            {
                $outputFile = "page_content.html"
            }
            Get-SinglePage -Url $url -OutputFile $outputFile
        }

        "2"
        {
            $url = Read-Host "Enter URL"
            Get-PageInfo -Url $url
        }

        "3"
        {
            $url = Read-Host "Enter URL"
            $folder = Read-Host "Download folder name"
            if ([string]::IsNullOrWhiteSpace($folder))
            {
                $folder = "downloaded_site"
            }
            $depthInput = Read-Host "Max link depth (0-3, default is 2)"
            $depth = 2
            if (-not [string]::IsNullOrWhiteSpace($depthInput))
            {
                $depth = [int]$depthInput
            }

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $fullFolder = "$folder`_$timestamp"

            Get-FullSite -Url $url -DownloadPath $fullFolder -Depth $depth
        }

        "4"
        {
            Write-Host "Exiting program..." -ForegroundColor Yellow
            break
        }

        default
        {
            Write-Host "Invalid option selected" -ForegroundColor Red
        }
    }

    if ($choice -ne "4")
    {
        Write-Host ""
        Read-Host "Press Enter to continue"
    }
}
while ($choice -ne "4")
