# —————————————————————————–
# Script: ChromeSync.ps1
# Author: ZFegan
# Date: 12/01/2019 10:59:44
# LastModified: 12/9/2019
# Version: 1
#
# —————————————————————————–
param (
    $Credential
)
Import-PSGSuiteConfig -Path "path\PSGSuiteconfig.json"
$log = "C:\windows\config\logs\JenkinsJobLogs\$ENV:JOB_NAME\Build$ENV:BUILD_NUMBER.log"
$TextInfo = (Get-Culture).TextInfo
$IgnoreList = @(secret exclusionlist)
[System.Collections.ArrayList]$ModifiedADUsers = @()
[System.Collections.ArrayList]$changes = @()
[System.Collections.ArrayList]$failures = @()


function New-RandomPassword {
    Add-Type -AssemblyName 'System.Web'
    $minLength = 10 ## characters
    $maxLength = 15 ## characters
    $length = Get-Random -Minimum $minLength -Maximum $maxLength
    $nonAlphaChars = 5
    [System.Web.Security.Membership]::GeneratePassword($length, $nonAlphaChars)
}

#Function for creating Google users
function Create-GSUser {
    [CmdletBinding()]

    Param
    (
        # Param1 help description
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)] $PrimaryEmail,

        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)] $FullName,
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)] $GivenName,
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)] $FamilyName,
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)] $OrgUnitPath

    )
    $Password = New-RandomPassword | ConvertTo-SecureString -AsPlainText -Force
    $NewGSUserParams = @{
        PrimaryEmail = $PrimaryEmail
        FullName     = $FullName
        GivenName    = $GivenName
        FamilyName   = $FamilyName
        OrgUnitPath  = $OrgUnitPath
        Password     = $Password
    }
    try {
        $newuser = New-GSUser @NewGSUserParams
    }
    catch {
        Write-Log "Failed to create user $FullName" -Level Error
    }
}
Write-Log "Gathering Users in the Chrome OU"
#Get all users in the Chrome Users OU
$ADUsers = (Get-ADGroup -Identity 'secretChromeOU'-properties members -Credential $Credential).members | Get-ADUser -Credential $Credential -Properties emailaddress, givenname, surname
#Get all users in Google
Write-Log "Gathering Google account users"
$GSUsers = Get-GSUser -Domain 'secretdomain' | where-object User -NotIn $IgnoreList | select @{n = 'PrimaryEmail'; e = { $_.User } }, 'FullName', 'GivenName', 'FamilyName', 'OrgUnitPath'

if (($ADUsers.count -gt 0) -and ($GSUsers.count -gt 0)) {
    Write-Log "Creating comparison objects for sync"
    foreach ($User in $ADUsers) {
        try {
            $Domain = "secretdomain"
            $EmailName = $User.emailaddress.Substring(0, $user.emailaddress.IndexOf('@'))
            $PrimaryEmail = $EmailName + '@' + $Domain
            $FirstName = $TextInfo.ToTitleCase($User.GivenName.ToLower())
            $LastName = $TextInfo.ToTitleCase($User.Surname.ToLower())
            $FullName = $FirstName + ' ' + $LastName
            $GivenName = $FirstName
            $OrgUnitPath = '/User Accounts/Users'

            $props = @{
                PrimaryEmail = $PrimaryEmail
                FullName     = $FirstName + ' ' + $LastName
                GivenName    = $FirstName
                FamilyName   = $LastName
                OrgUnitPath  = $OrgUnitPath
            }

            $obj = New-Object -TypeName pscustomobject -Property $props
            [void]$ModifiedADUsers.Add($obj)
        }
        catch {
            $failures.Add(($user.UserPrincipalName))
            continue
        }

    }
    Write-Log "Comparing Chrome and AD users to check for differences"
    $ComparedObjects = Compare-Object -ReferenceObject $ModifiedADUsers -DifferenceObject $GSUsers -Property PrimaryEmail -PassThru
    Write-Log "Syncing Chrome users"
    switch ($ComparedObjects) {
        { $_.sideindicator -eq '<=' } { $_ | Create-GSUser; [void]$changes.Add("Added $($_.PrimaryEmail) to Google account") }
        { $_.sideindicator -eq '=>' } { Remove-GSUser -User $_.PrimaryEmail -Confirm:$False; [void]$changes.Add("Deleted $($_.PrimaryEmail) from Google Account") }
        Default { Write-Log "No changes were detected" }
    }
    if ($changes.Count -gt 0) {
        $changes.Sort()
        $changes
    }
    else {
        Write-Log "There were no changes to be made"
    }

}
else {
    Write-Log "There was an error getting users from AD or Google" -Level Error
}

$server = 'emailserver'
$from = "email@email.com"
$to = 'zach.fegan@email.com'
$subject = "Users not added by ChromeSync"
$body = "The following users were unable to be added by chromesync
$failures"
Send-MailMessage -SmtpServer $server -From $from  -To $to -Subject $subject -body $body