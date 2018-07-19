#Requires -Version 3
###################################################
#              Abdurrahim  YILDIRIM               #
###################################################
 
Set-StrictMode -Version 3
Function Get-NtpTime {
 
    [CmdletBinding()]
    [OutputType()]
    Param (
        [String]$Server = 'pool.ntp.org',
        [Int]$MaxOffset = 1000000,     # (Milliseconds) Throw exception if network time offset is larger
        [Switch]$NoDns  = $True          # Do not attempt to lookup V3 secondary-server referenceIdentifier
    )
 
 
    # NTP Times are all UTC and are relative to midnight on 1/1/1900
    $StartOfEpoch=New-Object DateTime(1900,1,1,0,0,0,[DateTimeKind]::Utc)   
 
 
    Function OffsetToLocal($Offset) {
    # Convert milliseconds since midnight on 1/1/1900 to local time
        $StartOfEpoch.AddMilliseconds($Offset).ToLocalTime()
    }
 
 
    # Construct a 48-byte client NTP time packet to send to the specified server
    # (Request Header: [00=No Leap Warning; 011=Version 3; 011=Client Mode]; 00011011 = 0x1B)
 
    [Byte[]]$NtpData = ,0 * 48
    $NtpData[0] = 0x1B    # NTP Request header in first byte
 
 
    $Socket = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork,
                                            [Net.Sockets.SocketType]::Dgram,
                                            [Net.Sockets.ProtocolType]::Udp)
    $Socket.SendTimeOut = 2000  # ms
    $Socket.ReceiveTimeOut = 2000   # ms
 
    Try {
        $Socket.Connect($Server,123)
    }
    Catch {
        Write-Error "Failed to connect to server $Server"
        Throw 
    }
 
 
# NTP Transaction -------------------------------------------------------
 
        $t1 = Get-Date    # t1, Start time of transaction... 
    
        Try {
            [Void]$Socket.Send($NtpData)
            [Void]$Socket.Receive($NtpData)  
        }
        Catch {
            Write-Error "Failed to communicate with server $Server"
            Throw
        }
 
        $t4 = Get-Date    # End of NTP transaction time
 
# End of NTP Transaction ------------------------------------------------
 
    $Socket.Shutdown("Both") 
    $Socket.Close()
 
# We now have an NTP response packet in $NtpData to decode.  Start with the LI flag
# as this is used to indicate errors as well as leap-second information
 
    # Check the Leap Indicator (LI) flag for an alarm condition - extract the flag
    # from the first byte in the packet by masking and shifting 
 
    $LI = ($NtpData[0] -band 0xC0) -shr 6    # Leap Second indicator
    If ($LI -eq 3) {
        Throw 'Alarm condition from server (clock not synchronized)'
    } 
 
    # Decode the 64-bit NTP times
 
    # The NTP time is the number of seconds since 1/1/1900 and is split into an 
    # integer part (top 32 bits) and a fractional part, multipled by 2^32, in the 
    # bottom 32 bits.
 
    # Convert Integer and Fractional parts of the (64-bit) t3 NTP time from the byte array
    $IntPart = [BitConverter]::ToUInt32($NtpData[43..40],0)
    $FracPart = [BitConverter]::ToUInt32($NtpData[47..44],0)
 
    # Convert to Millseconds (convert fractional part by dividing value by 2^32)
    $t3ms = $IntPart * 1000 + ($FracPart * 1000 / 0x100000000)
 
    # Perform the same calculations for t2 (in bytes [32..39]) 
    $IntPart = [BitConverter]::ToUInt32($NtpData[35..32],0)
    $FracPart = [BitConverter]::ToUInt32($NtpData[39..36],0)
    $t2ms = $IntPart * 1000 + ($FracPart * 1000 / 0x100000000)
 
    # Calculate values for t1 and t4 as milliseconds since 1/1/1900 (NTP format)
    $t1ms = ([TimeZoneInfo]::ConvertTimeToUtc($t1) - $StartOfEpoch).TotalMilliseconds
    $t4ms = ([TimeZoneInfo]::ConvertTimeToUtc($t4) - $StartOfEpoch).TotalMilliseconds
 
    # Calculate the NTP Offset and Delay values
    $Offset = (($t2ms - $t1ms) + ($t3ms-$t4ms))/2
    $Delay = ($t4ms - $t1ms) - ($t3ms - $t2ms)
 
    # Make sure the result looks sane...
    If ([Math]::Abs($Offset) -gt $MaxOffset) {
        # Network server time is too different from local time
        Throw "Network time offset exceeds maximum ($($MaxOffset)ms)"
    }
 
    # Decode other useful parts of the received NTP time packet
 
    # We already have the Leap Indicator (LI) flag.  Now extract the remaining data
    # flags (NTP Version, Server Mode) from the first byte by masking and shifting (dividing)
 
    $LI_text = Switch ($LI) {
        0    {'no warning'}
        1    {'last minute has 61 seconds'}
        2    {'last minute has 59 seconds'}
        3    {'alarm condition (clock not synchronized)'}
    }
 
    $VN = ($NtpData[0] -band 0x38) -shr 3    # Server version number
 
    $Mode = ($NtpData[0] -band 0x07)     # Server mode (probably 'server')
    $Mode_text = Switch ($Mode) {
        0    {'reserved'}
        1    {'symmetric active'}
        2    {'symmetric passive'}
        3    {'client'}
        4    {'server'}
        5    {'broadcast'}
        6    {'reserved for NTP control message'}
        7    {'reserved for private use'}
    }
 
    # Other NTP information (Stratum, PollInterval, Precision)
 
    $Stratum = [UInt16]$NtpData[1]   # Actually [UInt8] but we don't have one of those...
    $Stratum_text = Switch ($Stratum) {
        0                            {'unspecified or unavailable'}
        1                            {'primary reference (e.g., radio clock)'}
        {$_ -ge 2 -and $_ -le 15}    {'secondary reference (via NTP or SNTP)'}
        {$_ -ge 16}                  {'reserved'}
    }
 
    $PollInterval = $NtpData[2]              # Poll interval - to neareast power of 2
    $PollIntervalSeconds = [Math]::Pow(2, $PollInterval)
 
    $PrecisionBits = $NtpData[3]      # Precision in seconds to nearest power of 2
    # ...this is a signed 8-bit int
    If ($PrecisionBits -band 0x80) {    # ? negative (top bit set)
        [Int]$Precision = $PrecisionBits -bor 0xFFFFFFE0    # Sign extend
    } else {
        # ..this is unlikely - indicates a precision of less than 1 second
        [Int]$Precision = $PrecisionBits   # top bit clear - just use positive value
    }
    $PrecisionSeconds = [Math]::Pow(2, $Precision)
    
 
    # Determine the format of the ReferenceIdentifier field and decode
    
    If ($Stratum -le 1) {
        # Response from Primary Server.  RefId is ASCII string describing source
        $ReferenceIdentifier = [String]([Char[]]$NtpData[12..15] -join '')
    }
    Else {
 
        # Response from Secondary Server; determine server version and decode
 
        Switch ($VN) {
            3       {
                        # Version 3 Secondary Server, RefId = IPv4 address of reference source
                        $ReferenceIdentifier = $NtpData[12..15] -join '.'
 
                        If (-Not $NoDns) {
                            If ($DnsLookup =  Resolve-DnsName $ReferenceIdentifier -QuickTimeout -ErrorAction SilentlyContinue) {
                                $ReferenceIdentifier = "$ReferenceIdentifier <$($DnsLookup.NameHost)>"
                            }
                        }
                        Break
                    }
 
            4       {
                        # Version 4 Secondary Server, RefId = low-order 32-bits of  
                        # latest transmit time of reference source
                        $ReferenceIdentifier = [BitConverter]::ToUInt32($NtpData[15..12],0) * 1000 / 0x100000000
                        Break
                    }
 
            Default {
                        # Unhandled NTP version...
                        $ReferenceIdentifier = $Null
                    }
        }
    }
 
 
    # Calculate Root Delay and Root Dispersion values
    
    $RootDelay = [BitConverter]::ToInt32($NtpData[7..4],0) / 0x10000
    $RootDispersion = [BitConverter]::ToUInt32($NtpData[11..8],0) / 0x10000
 
 
    # Finally, create output object and return
 
    $NtpTimeObj = [PSCustomObject]@{
        NtpServer = $Server
        NtpTime = OffsetToLocal($t4ms + $Offset)
        Offset = $Offset
        OffsetSeconds = [Math]::Round($Offset/1000, 3)
        Delay = $Delay
        t1ms = $t1ms
        t2ms = $t2ms
        t3ms = $t3ms
        t4ms = $t4ms
        t1 = OffsetToLocal($t1ms)
        t2 = OffsetToLocal($t2ms)
        t3 = OffsetToLocal($t3ms)
        t4 = OffsetToLocal($t4ms)
        LI = $LI
        LI_text = $LI_text
        NtpVersionNumber = $VN
        Mode = $Mode
        Mode_text = $Mode_text
        Stratum = $Stratum
        Stratum_text = $Stratum_text
        PollIntervalRaw = $PollInterval
        PollInterval = New-Object TimeSpan(0,0,$PollIntervalSeconds)
        Precision = $Precision
        PrecisionSeconds = $PrecisionSeconds
        ReferenceIdentifier = $ReferenceIdentifier
        RootDelay = $RootDelay
        RootDispersion = $RootDispersion
        Raw = $NtpData   # The undecoded bytes returned from the NTP server
    }
 
    # Set the default display properties for the returned object
    [String[]]$DefaultProperties =  'NtpServer', 'NtpTime', 'OffsetSeconds', 'NtpVersionNumber', 
                                    'Mode_text', 'Stratum', 'ReferenceIdentifier'
 
    # Create the PSStandardMembers.DefaultDisplayPropertySet member
    $ddps = New-Object Management.Automation.PSPropertySet('DefaultDisplayPropertySet', $DefaultProperties)
 
    # Attach default display property set and output object
    $PSStandardMembers = [Management.Automation.PSMemberInfo[]]$ddps 
    $NtpTimeObj | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value $PSStandardMembers -PassThru
}
	 $Servername = $env:computername
     $path_ntp = "C:\HPOOconfig\SystemControl\ntp_offset_control"
     $NTPserver = w32tm /query  /source|%{ $_.Split(',')[0]; }
     $NTPValue = Get-NtpTime $NTPserver
     $OffsetValue = $NTPValue.OffsetSeconds
     if ($OffsetValue -lt '-60000' -or $OffsetValue -gt '60000' -or !$OffsetValue)
     {
     Write-Host("NTP offset yüksek : $OffsetValue")
        if (Test-Path $path_ntp) 
        {
        Write-Host("Aler Dublicated")
        }
        else
        {
        opcmsg a=Offset o=Offset severity=Critical msg_text=" $servername NTP Offset Problem " node="$servername"
        echo $null >> $path_ntp
        }
     }
     else
     {
        if (Test-Path $path_ntp) 
        {
        opcmsg a=Offset o=Offset severity=Normal msg_text=" $servername NTP offset Fixed !!! " node="$servername"
        del $path_ntp
        }

     }
