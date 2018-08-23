
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateScript( {Test-Path $_})]
    [Alias('Fullname', 'Filename')]
    [string[]]$Filepath,

    [parameter()]
    [switch]$Force
)

begin {
    Import-Module MyModule -Verbose:$false | Out-Null

    [switch]$updateFile = $false

    function DoSomething {
        return 'something'
    }
}

process {
    foreach ($file in $Filepath) {
        Write-Verbose -Message "$file"
        <#
        this is a multiline comment
        this is a multiline comment
        this is a multiline comment
        #>

        switch ($file) {
            condition {
                Get-ChildItem -Path $file -Recurse | foreach {
                    if ($_.Extension -eq 'txt') {
                        # do something intelligent here
                        DoSomething
                    }
                }
            }

            Default {
                Write-Error -Exception ([System.Exception]::new("Excetpion Message"))
                throw 'An error has occurred'
            }
        }

        $hashTable = @{
            'value1'='one';
            'value2'='two'
        }

        $hereString = @"
this is an here-string, 
basically a multiline string variable
this is an here-string, 
basically a multiline string variable
"@

        try {
            $hashTable.GetEnumerator() | ForEach-Object {
                $_.Value
            }
        }
        catch [System.Exception] {
            Write-Error $_.Excepttion.Message
        }
    }
}