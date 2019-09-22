function Initialize-PodeSocketListenerEndpoint
{
    param(
        [Parameter(Mandatory=$true)]
        [ipaddress]
        $Address,

        [Parameter(Mandatory=$true)]
        [int]
        $Port,

        [Parameter()]
        [X509Certificate]
        $Certificate
    )

    $endpoint = [IPEndpoint]::new($Address, $Port)
    $socket = [System.Net.Sockets.Socket]::new($endpoint.AddressFamily, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)
    $socket.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::KeepAlive, $false)
    $socket.ReceiveTimeout = $PodeContext.Server.Sockets.ReceiveTimeout
    $socket.Bind($endpoint)
    $socket.Listen([int]::MaxValue)

    $PodeContext.Server.Sockets.Listeners += @{
        Socket = $socket
        Certificate = $Certificate
        Protocol = (Resolve-PodeValue -Check ($null -eq $Certificate) -TrueValue 'http' -FalseValue 'https')
    }
}

function New-PodeSocketListenerEvent
{
    param(
        [Parameter()]
        [int]
        $Index = 0
    )

    Lock-PodeObject -Object $PodeContext.Server.Sockets -Return -ScriptBlock {
        $socketArgs = [System.Net.Sockets.SocketAsyncEventArgs]::new()

        if ($Index -eq 0) {
            $PodeContext.Server.Sockets.MaxConnections++
            $Index = $PodeContext.Server.Sockets.MaxConnections
        }

        Register-ObjectEvent -InputObject $socketArgs -EventName 'Completed' -SourceIdentifier (Get-PodeSocketListenerConnectionEventName -Id $Index) -SupportEvent -Action {
            Invoke-PodeSocketProcessAccept -Arguments $Event.SourceEventArgs
        }

        return $socketArgs
    }
}

function Register-PodeSocketListenerEvents
{
    # populate the connections pool
    foreach ($i in (1..$PodeContext.Server.Sockets.MaxConnections)) {
        $socketArgs = New-PodeSocketListenerEvent -Index $i
        $PodeContext.Server.Sockets.Queues.Connections.Enqueue($socketArgs)
    }
}

function Start-PodeSocketListener
{
    foreach ($listener in $PodeContext.Server.Sockets.Listeners) {
        Invoke-PodeSocketAccept -Listener $listener
    }
}

function Get-PodeSocketContext
{
    return $PodeContext.Server.Sockets.Queues.Contexts.Take($PodeContext.Tokens.Cancellation.Token)
}

function Close-PodeSocket
{
    param(
        [Parameter(Mandatory=$true)]
        [System.Net.Sockets.Socket]
        $Socket,

        [switch]
        $Shutdown
    )

    if ($Shutdown -and $Socket.Connected) {
        $Socket.Shutdown([System.Net.Sockets.SocketShutdown]::Both)
    }

    Close-PodeDisposable -Disposable $Socket -Close
}

function Close-PodeSocketListener
{
    try {
        # close all open sockets
        $arr = $PodeContext.Server.Sockets.Queues.Contexts.ToArray()
        for ($i = $arr.Length - 1; $i -ge 0; $i--) {
            Close-PodeSocket -Socket $arr[$i] -Shutdown
        }

        $PodeContext.Server.Sockets.Queues.Contexts.Dispose()

        # close all open listeners and unbind events
        for ($i = $PodeContext.Server.Sockets.Listeners.Length - 1; $i -ge 0; $i--) {
            Close-PodeSocket -Socket $PodeContext.Server.Sockets.Listeners[$i].Socket -Shutdown
        }

        $PodeContext.Server.Sockets.Listeners = @()
    }
    catch {
        $_.Exception | Out-Default
    }
}

function Invoke-PodeSocketAccept
{
    param(
        [Parameter(Mandatory=$true)]
        $Listener
    )

    # pop args from queue (or create a new one)
    $arguments = $null
    if (!$PodeContext.Server.Sockets.Queues.Connections.TryDequeue([ref]$arguments)) {
        $arguments = New-PodeSocketListenerEvent
    }

    $arguments.AcceptSocket = $null
    $arguments.UserToken = $Listener
    $raised = $false

    try {
        $raised = $arguments.UserToken.Socket.AcceptAsync($arguments)
    }
    catch [System.ObjectDisposedException] {
        return
    }

    if (!$raised) {
        Invoke-PodeSocketProcessAccept -Arguments $arguments
    }
}

function Invoke-PodeSocketProcessAccept
{
    param(
        [Parameter(Mandatory=$true)]
        [System.Net.Sockets.SocketAsyncEventArgs]
        $Arguments
    )

    # get the socket and listener
    $accepted = $Arguments.AcceptSocket
    $listener = $Arguments.UserToken

    # reset the socket args
    $Arguments.AcceptSocket = $null
    $Arguments.UserToken = $null

    # start accepting connections again for the listener
    Invoke-PodeSocketAccept -Listener $listener

    # if not success, close this accept socket and accept again
    if (($null -eq $accepted) -or ($Arguments.SocketError -ne [System.Net.Sockets.SocketError]::Success) -or ($accepted.Available -eq 0)) {
        # close socket
        if ($null -ne $accepted) {
            $accepted.Close()
        }

        # add args back to pool
        $PodeContext.Server.Sockets.Queues.Connections.Enqueue($Arguments)
        return
    }

    # add args back to pool
    $PodeContext.Server.Sockets.Queues.Connections.Enqueue($Arguments)
    Register-PodeSocketContext -Socket $accepted -Certificate $listener.Certificate -Protocol $listener.Protocol
}

function Register-PodeSocketContext
{
    param(
        [Parameter(Mandatory=$true)]
        [System.Net.Sockets.Socket]
        $Socket,

        [Parameter()]
        [X509Certificate]
        $Certificate,

        [Parameter()]
        [string]
        $Protocol
    )

    if (!$Socket.Connected) {
        Close-PodeSocket -Socket $Socket -Shutdown
    }

    $PodeContext.Server.Sockets.Queues.Contexts.Add(@{
        Socket = $Socket
        Certificate = $Certificate
        Protocol = $Protocol
    }, $PodeContext.Tokens.Cancellation.Token)
}

function Get-PodeSocketListenerConnectionEventName
{
    param (
        [Parameter(Mandatory=$true)]
        [int]
        $Id
    )

    return "PodeListenerConnectionSocketCompleted_$($Id)"
}