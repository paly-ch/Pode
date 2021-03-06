function Get-PodeRoute
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet('DELETE', 'GET', 'HEAD', 'MERGE', 'OPTIONS', 'PATCH', 'POST', 'PUT', 'TRACE', 'STATIC', '*')]
        [string]
        $Method,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Route,

        [Parameter()]
        [string]
        $Protocol,

        [Parameter()]
        [string]
        $Endpoint,

        [switch]
        $CheckWildMethod
    )

    # first, if supplied, check the wildcard method
    if ($CheckWildMethod -and $PodeContext.Server.Routes['*'].Count -ne 0) {
        $found = Get-PodeRoute -Method '*' -Route $Route -Protocol $Protocol -Endpoint $Endpoint
        if ($null -ne $found) {
            return $found
        }
    }

    # is this a static route?
    $isStatic = ($Method -ieq 'static')

    # first ensure we have the method
    $_method = $PodeContext.Server.Routes[$Method]
    if ($null -eq $_method) {
        return $null
    }

    # if we have a perfect match for the route, return it if the protocol is right
    $found = Get-PodeRouteByUrl -Routes $_method[$Route] -Protocol $Protocol -Endpoint $Endpoint
    if (!$isStatic -and $null -ne $found) {
        return @{
            Logic = $found.Logic
            Middleware = $found.Middleware
            Protocol = $found.Protocol
            Endpoint = $found.Endpoint
            ContentType = $found.ContentType
            ErrorType = $found.ErrorType
            Parameters = $null
            Arguments = $found.Arguments
        }
    }

    # otherwise, attempt to match on regex parameters
    else {
        $valid = @(foreach ($key in $_method.Keys) {
            if ($Route -imatch "^$($key)$") {
                $key
            }
        })[0]

        if ($null -eq $valid) {
            return $null
        }

        $found = Get-PodeRouteByUrl -Routes $_method[$valid] -Protocol $Protocol -Endpoint $Endpoint
        if ($null -eq $found) {
            return $null
        }

        $Route -imatch "$($valid)$" | Out-Null

        if ($isStatic) {
            return @{
                Path = $found.Path
                Defaults = $found.Defaults
                Protocol = $found.Protocol
                Endpoint = $found.Endpoint
                Download = $found.Download
                File = $Matches['file']
            }
        }
        else {
            return @{
                Logic = $found.Logic
                Middleware = $found.Middleware
                Protocol = $found.Protocol
                Endpoint = $found.Endpoint
                ContentType = $found.ContentType
                ErrorType = $found.ErrorType
                Parameters = $Matches
                Arguments = $found.Arguments
            }
        }
    }
}

function Get-PodeStaticRoutePath
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Route,

        [Parameter()]
        [string]
        $Protocol,

        [Parameter()]
        [string]
        $Endpoint
    )

    # attempt to get a static route for the path
    $found = Get-PodeRoute -Method 'static' -Route $Route -Protocol $Protocol -Endpoint $Endpoint
    $havePublicDir = (![string]::IsNullOrWhiteSpace($PodeContext.Server.InbuiltDrives['public']))
    $path = $null
    $download = $false

    # if we have a defined static route, use that
    if ($null -ne $found) {
        # is the found route set as download only?
        if ($found.Download) {
            $download = $true
            $found.File = (Protect-PodeValue -Value $found.File -Default ([string]::Empty))
        }

        # if there's no file, we need to check defaults
        elseif (!(Test-PodePathIsFile $found.File) -and (Get-PodeCount @($found.Defaults)) -gt 0)
        {
            $found.File = (Protect-PodeValue -Value $found.File -Default ([string]::Empty))

            if ((Get-PodeCount @($found.Defaults)) -eq 1) {
                $found.File = Join-PodePaths @($found.File, @($found.Defaults)[0])
            }
            else {
                foreach ($def in $found.Defaults) {
                    if (Test-PodePath (Join-Path $found.Path $def) -NoStatus) {
                        $found.File = Join-PodePaths @($found.File, $def)
                        break
                    }
                }
            }
        }

        $path = (Join-Path $found.Path $found.File)
    }

    # use the public static directory (but only if path is a file, and a public dir is present)
    if ($havePublicDir -and (Test-PodePathIsFile $Route) -and !(Test-PodePath -Path $path -NoStatus)) {
        $path = (Join-Path $PodeContext.Server.InbuiltDrives['public'] $Route)
    }

    # return the route details
    return @{
        Path = $path
        Download = $download
    }
}

function Get-PodeRouteByUrl
{
    param (
        [Parameter()]
        [hashtable[]]
        $Routes,

        [Parameter()]
        [string]
        $Protocol,

        [Parameter()]
        [string]
        $Endpoint
    )

    # get the routes
    $rs = @(Get-PodeRoutesByUrl -Routes $Routes -Protocol $Protocol -Endpoint $Endpoint)

    # return null if empty
    if (($rs.Length -eq 0) -or ($null -eq $rs[0])) {
        return $null
    }

    return @($rs | Sort-Object -Property { $_.Protocol }, { $_.Endpoint } -Descending)[0]
}

function Get-PodeRoutesByUrl
{
    param (
        [Parameter()]
        [hashtable[]]
        $Routes,

        [Parameter()]
        [string]
        $Protocol,

        [Parameter()]
        [string]
        $Endpoint
    )

    # get the routes for the protocol/endpoint
    return @(foreach ($route in $Routes) {
        if (
            (($route.Protocol -ieq $Protocol) -or [string]::IsNullOrWhiteSpace($route.Protocol)) -and
            ([string]::IsNullOrWhiteSpace($route.Endpoint) -or ($Endpoint -ilike $route.Endpoint))
        ) {
            $route
        }
    })
}

function Update-PodeRoutePlaceholders
{
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path
    )

    # replace placeholder parameters with regex
    $placeholder = '\:(?<tag>[\w]+)'
    if ($Path -imatch $placeholder) {
        $Path = [regex]::Escape($Path)
    }

    while ($Path -imatch $placeholder) {
        $Path = ($Path -ireplace $Matches[0], "(?<$($Matches['tag'])>[^\/]+?)")
    }

    return $Path
}

function ConvertTo-PodeOpenApiRoutePath
{
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path
    )

    # replace placeholder parameters with regex
    $placeholder = '\:(?<tag>[\w]+)'
    if ($Path -imatch $placeholder) {
        $Path = [regex]::Escape($Path)
    }

    while ($Path -imatch $placeholder) {
        $Path = ($Path -ireplace $Matches[0], "{$($Matches['tag'])}")
    }

    return $Path
}

function Update-PodeRouteSlashes
{
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path,

        [switch]
        $Static
    )

    # ensure route starts with a '/'
    if (!$Path.StartsWith('/')) {
        $Path = "/$($Path)"
    }

    if ($Static) {
        # ensure the static route ends with '/{0,1}.*'
        $Path = $Path.TrimEnd('/*')
        $Path = "$($Path)[/]{0,1}(?<file>*)"
    }

    # replace * with .*
    $Path = ($Path -ireplace '\*', '.*')
    return $Path
}

function Split-PodeRouteQuery
{
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path
    )

    return ($Path -isplit "\?")[0]
}

function ConvertTo-PodeRouteRegex
{
    param (
        [Parameter()]
        [string]
        $Path
    )

    $Path = Protect-PodeValue -Value $Path -Default '/'
    $Path = Split-PodeRouteQuery -Path $Path
    $Path = Protect-PodeValue -Value $Path -Default '/'
    $Path = Update-PodeRouteSlashes -Path $Path
    $Path = Update-PodeRoutePlaceholders -Path $Path

    return $Path
}

function Get-PodeStaticRouteDefaults
{
    if (!(Test-IsEmpty $PodeContext.Server.Web.Static.Defaults)) {
        return @($PodeContext.Server.Web.Static.Defaults)
    }

    return @(
        'index.html',
        'index.htm',
        'default.html',
        'default.htm'
    )
}

function Test-PodeRouteAndError
{
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Method,

        [Parameter(Mandatory=$true)]
        [string]
        $Path,

        [Parameter()]
        [string]
        $Protocol,

        [Parameter()]
        [string]
        $Endpoint
    )

    $found = @($PodeContext.Server.Routes[$Method][$Path])

    if (($found | Where-Object { ($_.Protocol -ieq $Protocol) -and ($_.Endpoint -ieq $Endpoint) } | Measure-Object).Count -eq 0) {
        return
    }

    $_url = $Protocol
    if (![string]::IsNullOrEmpty($_url) -and ![string]::IsNullOrWhiteSpace($Endpoint)) {
        $_url = "$($_url)://$($Endpoint)"
    }
    elseif (![string]::IsNullOrWhiteSpace($Endpoint)) {
        $_url = $Endpoint
    }

    if ([string]::IsNullOrEmpty($_url)) {
        throw "[$($Method)] $($Path): Already defined"
    }
    else {
        throw "[$($Method)] $($Path): Already defined for $($_url)"
    }
}

function Get-PodeEndpointByName
{
    param (
        [Parameter()]
        [string]
        $EndpointName,

        [switch]
        $ThrowError
    )

    # if an EndpointName was supplied, find it and use it
    if ([string]::IsNullOrWhiteSpace($EndpointName)) {
        return $null
    }

    # ensure it exists
    $found = $(foreach ($i in $PodeContext.Server.Endpoints) {
            if ($i.name -ieq $EndpointName) {
                $i
                break
            }
        }
    )

    if ($null -eq $found) {
        if ($ThrowError) {
            throw "Endpoint with name '$($EndpointName)' does not exist"
        }

        return $null
    }

    return $found
}

function Find-PodeEndpoints
{
    param(
        [Parameter()]
        [ValidateSet('', 'Http', 'Https')]
        [string]
        $Protocol,

        [Parameter()]
        [string]
        $Endpoint,

        [Parameter()]
        [string[]]
        $EndpointName
    )

    $endpoints = @()

    # just use a single endpoint/protocol
    if ([string]::IsNullOrWhiteSpace($EndpointName)) {
        $endpoints += @{
            Protocol = $Protocol
            Address = $Endpoint
        }
    }

    # get all defined endpoints by name
    else {
        foreach ($name in @($EndpointName)) {
            $_endpoint = Get-PodeEndpointByName -EndpointName $name -ThrowError
            if ($null -ne $_endpoint) {
                $endpoints += @{
                    Protocol = $_endpoint.Protocol
                    Address = $_endpoint.RawAddress
                }
            }
        }
    }

    # convert the endpoint's address into host:port format
    foreach ($_endpoint in $endpoints) {
        if (![string]::IsNullOrWhiteSpace($_endpoint.Address)) {
            $_addr = Get-PodeEndpointInfo -Endpoint $_endpoint.Address -AnyPortOnZero
            $_endpoint.Address = "$($_addr.Host):$($_addr.Port)"
        }
    }

    return $endpoints
}

function Convert-PodeFunctionVerbToHttpMethod
{
    param (
        [Parameter()]
        [string]
        $Verb
    )

    # if empty, just return default
    switch ($Verb) {
        { $_ -iin @('Find', 'Format', 'Get', 'Join', 'Search', 'Select', 'Split', 'Measure', 'Ping', 'Test', 'Trace') } { 'GET' }
        { $_ -iin @('Set') } { 'PUT' }
        { $_ -iin @('Rename', 'Edit', 'Update') } { 'PATCH' }
        { $_ -iin @('Clear', 'Close', 'Exit', 'Hide', 'Remove', 'Undo', 'Dismount', 'Unpublish', 'Disable', 'Uninstall', 'Unregister') } { 'DELETE' }
        Default { 'POST' }
    }
}
