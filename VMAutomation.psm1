function New-AutoDeployVM {
    [CmdletBinding()]
    Param(
        # Used to name the virtual machine, set up DNS records and register with the DHCP server.
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Name,

        # Specifies the target Hyper-V Server.
        [Parameter(Mandatory=$true, Position=1)]
        [string]$VMHost,

        # The directory used to store the vm will be $Path\$Name
        [string]$Path="D:\AutoDeployVMS",

        # Specifies the number of CPU Cores. Defaults to 1.
        [int]$CPUCount=1,

        # Wether to use dynamic ram or not
        [switch]$DynamicRam,

        # Specifies Startup Memory.
        [int64]$StartUpRam=1024MB,

        # Specifies the Minimum amount of dynamic.
        [int64]$MinRam=512MB,

        # Specifies the Maximum amount of dynamic.
        [int64]$MaxRam=2048MB,

        [UInt64]$DiskSize=40GB,

        [string]$SwitchName="BackBone",

        [IPAddress]$SubnetAddress,

        [ValidateSet("Nothing", "Start", "StartIfRunning")]
        [string]$AutomaticStartAction = "StartIfRunning",

        [ValidateSet("Save", "ShutDown", "TurnOff")]
        [string]$AutomaticStopAction = "ShutDown",

        [int64]$AutomaticStartDelay=60,

        [string]$ISOPath="F:\ISOs\Debian\Debian-10.6.0.iso",

        # Notes that can be added to the VM.  
        [string]$Notes="AutoGenerated VM"
    )

    # Set up the required directories
    $VMDir = "$Path\$Name"
    Invoke-Command -ComputerName $VMHost -ScriptBlock {
        param($VMDir)
        New-Item -Path $VMDir -ItemType Directory
        New-Item -Path "$VMDir\VM" -ItemType Directory
    } -Args $VMDir

    # Creating the VM with all the required bells and whistles
    New-VM -Name $Name -ComputerName $VMHost `
    -NoVHD -Path "$VMDir\VM" `
    -MemoryStartupBytes $StartUpRam -SwitchName $SwitchName `
    -Generation 2 -BootDevice "CD"

    Set-VM -Name $Name -ComputerName $VMHost -ProcessorCount $CPUCount `
    -AutomaticStartAction $AutomaticStartAction -AutomaticStopAction $AutomaticStopAction `
    -AutomaticStartDelay $AutomaticStartDelay -Notes $Notes

    if ($DynamicRam) {
        Set-VM -Name $Name -ComputerName $VMHost -DynamicMemory -MemoryMinimumBytes $MinRam -MemoryMaximumBytes $MaxRam
    }
    Set-VMFirmware -VMName $Name -ComputerName $VMHost -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
    Set-VMDvdDrive -VMName $Name -ComputerName $VMHost -Path $ISOPath

    # Create the virtual hard disk
    $VHDPath = "$VMDir\$Name.vhdx"
    New-VHD -ComputerName $VMHost -Path $VHDPath -Dynamic -SizeBytes 40GB
    Add-VMHardDiskDrive -ComputerName $VMHost -VMName $Name -Path $VHDPath

    # Hyper-V generates a semi-random MacAddress at first boot
    Start-VM -ComputerName $VMHost -Name $Name
    Stop-VM -ComputerName $VMHost -Name $Name -TurnOff
    $MacAddress = (Get-VMNetworkAdapter -VMName $Name -ComputerName $VMHost).MacAddress
    Get-VMNetworkAdapter -VMName $Name -ComputerName $VMHost | Set-VMNetworkAdapter -StaticMacAddress $MacAddress

    # Register the IP in DHCP
    $IPAddress = Get-DhcpServerv4FreeIPAddress -ScopeId $SubnetAddress
    Add-DhcpServerv4Reservation -IPAddress $IPAddress -ScopeId $SubnetAddress -ClientId $MacAddress `
        -Name $Name -Description "Auto generated lease for VM autodeploy"
    Add-DhcpServerv4Filter -List Allow -MacAddress $MacAddress -Description $Name

    # Register in DNS
    Add-DnsServerResourceRecordA -Name $Name -CreatePtr -AllowUpdateAny -IPv4Address $IPAddress -AgeRecord -ZoneName ServerCademy.local
}

function Remove-AutoDeployVM {
    [CmdletBinding()]
    param (
        # Name of the VM, dns records, dhcp lease etc.
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Name,

        # The Hyper-V server hosting the machine.
        [Parameter(Mandatory=$true, Position=1)]
        [string]$VMHost,

        # The directory used to store the vm will be $Path\$Name
        [string]$Path="D:\AutoDeployVMS"
    )

    # Kill the VM if it is running
    Stop-VM -ComputerName $VMHost -Name $Name -TurnOff -WarningAction SilentlyContinue

    # Clean up DNS
    (Get-DnsServerResourceRecord -RRType Ptr -ZoneName 16.172.in-addr.arpa) `
        | Where-Object {$_.RecordData.PtrDomainName -eq "$Name.ServerCademy.local."} `
        | Remove-DnsServerResourceRecord -ZoneName 16.172.in-addr.arpa -Force
    Remove-DnsServerResourceRecord -ZoneName ServerCademy.local -RRType "A" -Name $Name -Force

    # Clean up DHCP
    $MacAddress = (Get-VMNetworkAdapter -VMName $Name -ComputerName $VMHost).MacAddress
    Remove-DhcpServerv4Filter -MacAddress $MacAddress
    foreach ($Scope in Get-DhcpServerv4Scope) {
        Remove-DhcpServerv4Reservation -ScopeId $Scope.ScopeId.IPAddressToString -ClientId $MacAddress
    }

    # Remove VM
    Remove-VM -ComputerName $VMHost -Name $Name -Force

    # Clean up Files
    Invoke-Command -ComputerName $VMHost -ScriptBlock {
        param($Name, $Path)
        Remove-Item -Path "$Path\$Name" -Recurse -Force
    } -Args $Name, $Path
}
