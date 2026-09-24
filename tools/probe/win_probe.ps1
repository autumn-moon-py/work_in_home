# 局域网广播探针（Windows 侧）
#
# 依赖零安装：使用 .NET UdpClient，无需 Dart 或 Python。
# 用法：
#   powershell -ExecutionPolicy Bypass -File win_probe.ps1 -Seconds 60
# 若收不到任何包，通常需要先放行入站 UDP（见对话中的命令）。
#
# 注意：运行时输出刻意使用 ASCII 标记，避免 Windows PowerShell 5.1 对 UTF-8
# 中文脚本的编码误判导致输出乱码。
param(
    [int]$Port = 47823,
    [int]$Seconds = 60
)

$ErrorActionPreference = 'Stop'

$Udp = New-Object System.Net.Sockets.UdpClient
$Udp.Client.SetSocketOption(
    [System.Net.Sockets.SocketOptionLevel]::Socket,
    [System.Net.Sockets.SocketOptionName]::ReuseAddress,
    $true
)
$Udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
$Udp.EnableBroadcast = $true

Write-Host '[IFACES]'
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -ne '127.0.0.1' } |
    ForEach-Object { Write-Host ("  {0,-16} {1}" -f $_.InterfaceAlias, $_.IPAddress) }

$Targets = @(
    [System.Net.IPAddress]::Broadcast,
    [System.Net.IPAddress]::Parse('10.174.206.255')
)

$Beacon = @{
    magic = 'work_in_home-probe-v1'
    host  = $env:COMPUTERNAME
    os    = 'windows'
    ts    = (Get-Date).ToString('o')
} | ConvertTo-Json -Compress
$Payload = [System.Text.Encoding]::UTF8.GetBytes($Beacon)

Write-Host ("[LISTEN] port={0} seconds={1}" -f $Port, $Seconds)
$Deadline = (Get-Date).AddSeconds($Seconds)

while ((Get-Date) -lt $Deadline) {
    while ($Udp.Available -gt 0) {
        $Remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $Data = $Udp.Receive([ref]$Remote)
        Write-Host ("[RECV] {0} from={1}:{2} {3}" -f `
            (Get-Date -Format o), $Remote.Address, $Remote.Port,
            [System.Text.Encoding]::UTF8.GetString($Data))
    }

    foreach ($Target in $Targets) {
        $Endpoint = New-Object System.Net.IPEndPoint($Target, $Port)
        $Udp.Send($Payload, $Payload.Length, $Endpoint) | Out-Null
    }
    Write-Host ("[SEND] {0}" -f (Get-Date -Format o))

    Start-Sleep -Seconds 2
}

$Udp.Close()
Write-Host '[DONE]'
