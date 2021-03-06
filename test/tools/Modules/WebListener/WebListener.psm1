Class WebListener
{
    [int]$HttpPort
    [int]$HttpsPort
    [int]$Tls11Port
    [int]$TlsPort
    [System.Management.Automation.Job]$Job

    WebListener () { }

    [String] GetStatus()
    {
        return $This.Job.JobStateInfo.State
    }
}

[WebListener]$WebListener

function Get-WebListener
{
    [CmdletBinding(ConfirmImpact = 'Low')]
    [OutputType([WebListener])]
    param()

    process
    {
        return [WebListener]$Script:WebListener
    }
}

function Start-WebListener
{
    [CmdletBinding(ConfirmImpact = 'Low')]
    [OutputType([WebListener])]
    param
    (
        [ValidateRange(1,65535)]
        [int]$HttpPort = 8083,

        [ValidateRange(1,65535)]
        [int]$HttpsPort = 8084,

        [ValidateRange(1,65535)]
        [int]$Tls11Port = 8085,

        [ValidateRange(1,65535)]
        [int]$TlsPort = 8086
    )

    process
    {
        $runningListener = Get-WebListener
        if ($null -ne $runningListener -and $runningListener.GetStatus() -eq 'Running')
        {
            return $runningListener
        }

        $initTimeoutSeconds  = 15
        $appDll              = 'WebListener.dll'
        $serverPfx           = 'ServerCert.pfx'
        $serverPfxPassword   = 'password'
        $initCompleteMessage = 'Now listening on'
        $sleepMilliseconds   = 100

        $serverPfxPath = Join-Path $MyInvocation.MyCommand.Module.ModuleBase $serverPfx
        $Job = Start-Job {
            $path = Split-Path -parent (get-command WebListener).Path -Verbose
            Push-Location $path -Verbose
            'appDLL: {0}' -f $using:appDll
            'serverPfxPath: {0}' -f $using:serverPfxPath
            'serverPfxPassword: {0}' -f $using:serverPfxPassword
            'HttpPort: {0}' -f $using:HttpPort
            'Https: {0}' -f $using:HttpsPort
            'Tls11Port: {0}' -f $using:Tls11Port
            'TlsPort: {0}' -f $using:TlsPort
            $env:ASPNETCORE_ENVIRONMENT = 'Development'
            dotnet $using:appDll $using:serverPfxPath $using:serverPfxPassword $using:HttpPort $using:HttpsPort $using:Tls11Port $using:TlsPort
        }
        $Script:WebListener = [WebListener]@{
            HttpPort  = $HttpPort
            HttpsPort = $HttpsPort
            Tls11Port = $Tls11Port
            TlsPort   = $TlsPort
            Job       = $Job
        }

        # Count iterations of $sleepMilliseconds instead of using system time to work around possible CI VM sleep/delays
        $sleepCountRemaining = $initTimeoutSeconds * 1000 / $sleepMilliseconds
        do
        {
            Start-Sleep -Milliseconds $sleepMilliseconds
            $initStatus = $Job.ChildJobs[0].Output | Out-String
            $isRunning = $initStatus -match $initCompleteMessage
            $sleepCountRemaining--
        }
        while (-not $isRunning -and $sleepCountRemaining -gt 0)

        if (-not $isRunning)
        {
            $jobErrors = $Job.ChildJobs[0].Error | Out-String
            $jobOutput =  $Job.ChildJobs[0].Output | Out-String
            $jobVerbose =  $Job.ChildJobs[0].Verbose | Out-String
            $Job | Stop-Job
            $Job | Remove-Job -Force
            $message = 'WebListener did not start before the timeout was reached.{0}Errors:{0}{1}{0}Output:{0}{2}{0}Verbose:{0}{3}' -f
                ([System.Environment]::NewLine), $jobErrors, $jobOutput, $jobVerbose
            throw $message
        }
        return $Script:WebListener
    }
}

function Stop-WebListener
{
    [CmdletBinding(ConfirmImpact = 'Low')]
    [OutputType([Void])]
    param()

    process
    {
        $Script:WebListener.job | Stop-Job -PassThru | Remove-Job
        $Script:WebListener = $null
    }
}

function Get-WebListenerClientCertificate {
    [CmdletBinding(ConfirmImpact = 'Low')]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param()
    process {
        $pfxPath = Join-Path $MyInvocation.MyCommand.Module.ModuleBase 'ClientCert.pfx'
        [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfxPath,'password')
    }
}

function Get-WebListenerUrl {
    [CmdletBinding()]
    [OutputType([Uri])]
    param (
        [switch]$Https,

        [ValidateSet('Default', 'Tls12', 'Tls11', 'Tls')]
        [string]$SslProtocol = 'Default',

        [ValidateSet(
            'Auth',
            'Cert',
            'Compression',
            'Delay',
            'Delete',
            'Encoding',
            'Get',
            'Home',
            'Link',
            'Multipart',
            'Patch',
            'Post',
            'Put',
            'Redirect',
            'Response',
            'ResponseHeaders',
            '/'
        )]
        [String]$Test,

        [String]$TestValue,

        [System.Collections.IDictionary]$Query
    )
    process {
        $runningListener = Get-WebListener
        if ($null -eq $runningListener -or $runningListener.GetStatus() -ne 'Running')
        {
            return $null
        }
        $Uri = [System.UriBuilder]::new()
        # Use 127.0.0.1 and not localhost due to https://github.com/dotnet/corefx/issues/24104
        $Uri.Host = '127.0.0.1'
        $Uri.Port = $runningListener.HttpPort
        $Uri.Scheme = 'Http'

        if ($Https.IsPresent)
        {
            switch ($SslProtocol)
            {
                'Tls11' { $Uri.Port = $runningListener.Tls11Port }
                'Tls'   { $Uri.Port = $runningListener.TlsPort }
                # The base HTTPs port is configured for Tls12 only
                default { $Uri.Port = $runningListener.HttpsPort }
            }
            $Uri.Scheme = 'Https'
        }

        if ($TestValue)
        {
            $Uri.Path = '{0}/{1}' -f $Test, $TestValue
        }
        else
        {
            $Uri.Path = $Test
        }
        $StringBuilder = [System.Text.StringBuilder]::new()
        foreach ($key in $Query.Keys)
        {
            $null = $StringBuilder.Append([System.Net.WebUtility]::UrlEncode($key))
            $null = $StringBuilder.Append('=')
            $null = $StringBuilder.Append([System.Net.WebUtility]::UrlEncode($Query[$key].ToString()))
            $null = $StringBuilder.Append('&')
        }
        $Uri.Query = $StringBuilder.ToString()

        return [Uri]$Uri.ToString()
    }
}
