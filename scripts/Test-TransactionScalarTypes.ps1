#Requires -Version 5.1
[CmdletBinding()]
param([string]$TemporaryParent = [IO.Path]::GetTempPath())
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$parent=Resolve-FullPath -Path $TemporaryParent -MustExist -PathType Container
$root=Join-Path $parent ('transaction-scalars-'+[guid]::NewGuid().ToString('N'))
$hostExe=if($PSVersionTable.PSEdition -ceq 'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
$utf8=New-Object Text.UTF8Encoding($false)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Write-Json([string]$Path,[object]$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Compress -Depth 30),$utf8)}
function Copy-Value([object]$Value){ConvertFrom-Json -InputObject ($Value|ConvertTo-Json -Compress -Depth 30)}
function New-Archive([string]$Path,[string]$Value){
    $content=$utf8.GetBytes($Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($content))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try{
        foreach($entry in @(@{name='fixture/payload.txt';bytes=$content},@{name='fixture/checksums.sha256';bytes=$utf8.GetBytes($hash+' *payload.txt'+"`n")})){
            $item=$zip.CreateEntry($entry.name,[IO.Compression.CompressionLevel]::NoCompression)
            $out=$item.Open();try{$out.Write($entry.bytes,0,$entry.bytes.Length)}finally{$out.Dispose()}
        }
    }finally{$zip.Dispose();$stream.Dispose()}
}
function New-Fixture([string]$Directory,[switch]$Prior){
    [IO.Directory]::CreateDirectory($Directory)|Out-Null
    $leaf='mql5-chm-mcp-windows-x64.zip';$token='7'*32;$id='9'*32
    $zipPrepared='.package-'+$token+'.prepared.zip';$manifestPrepared='.package-'+$token+'.prepared.manifest.json'
    New-Archive (Join-Path $Directory $zipPrepared) 'independently specified candidate payload'
    $zipFile=Get-Item -LiteralPath (Join-Path $Directory $zipPrepared)
    $hash=(Get-FileHash -LiteralPath $zipFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Json (Join-Path $Directory $manifestPrepared) ([ordered]@{schema_version=1;file=$leaf;bytes=$zipFile.Length;sha256=$hash})
    if($Prior){
        New-Archive (Join-Path $Directory $leaf) 'independently specified prior payload'
        $old=Get-Item -LiteralPath (Join-Path $Directory $leaf)
        Write-Json (Join-Path $Directory ($leaf+'.manifest.json')) ([ordered]@{schema_version=1;file=$leaf;bytes=$old.Length;sha256=(Get-FileHash -LiteralPath $old.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    $items=@()
    foreach($pair in @(@($leaf,$zipPrepared),@(($leaf+'.manifest.json'),$manifestPrepared))){
        $candidate=Get-Item -LiteralPath (Join-Path $Directory $pair[1])
        $oldBytes=$null;$oldHash=$null
        if($Prior){$old=Get-Item -LiteralPath (Join-Path $Directory $pair[0]);$oldBytes=$old.Length;$oldHash=(Get-FileHash -LiteralPath $old.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        $items+=@([pscustomobject][ordered]@{target=$pair[0];prepared=$pair[1];backup=('.'+$pair[0]+'.backup-'+$id);old_present=[bool]$Prior;old_bytes=$oldBytes;old_sha256=$oldHash;new_bytes=$candidate.Length;new_sha256=(Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    return [pscustomobject][ordered]@{schema_version=2;operation='publish-prepared-file-set';transaction_id=$id;role='portable-zip';items=$items}
}
function Read-Definition([string]$Directory){
    $leaf='mql5-chm-mcp-windows-x64.zip';$name='.'+$leaf+'.publication-transaction.json'
    Get-PreparedFileSetTransactionDefinition -Root $Directory -JournalName $name -JournalPath (Join-Path $Directory $name) -ExpectedRole portable-zip -ExpectedTargetNames @($leaf,($leaf+'.manifest.json'))
}
function Set-Field([object]$Value,[string]$Field,[AllowNull()][object]$Replacement){
    if($Field.StartsWith('item.')){$Value.items[0].PSObject.Properties[$Field.Substring(5)].Value=$Replacement}
    else{$Value.PSObject.Properties[$Field].Value=$Replacement}
}
try{
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $leaf='mql5-chm-mcp-windows-x64.zip';$journalName='.'+$leaf+'.publication-transaction.json'
    $fields=@('operation','transaction_id','role','item.target','item.prepared','item.backup','item.old_sha256','item.new_sha256','schema_version','item.old_present','item.old_bytes','item.new_bytes')
    $fixtureRoot=Join-Path $root 'reader';$value=New-Fixture $fixtureRoot -Prior
    $path=Join-Path $fixtureRoot $journalName
    Write-Json $path $value
    Read-Definition $fixtureRoot|Out-Null;$checks++
    foreach($field in $fields){
        $original=if($field.StartsWith('item.')){$value.items[0].PSObject.Properties[$field.Substring(5)].Value}else{$value.PSObject.Properties[$field].Value}
        foreach($kind in @('singleton','multiple','empty','object','wrong-scalar')){
            $bad=Copy-Value $value
            $replacement=switch($kind){
                'singleton'{,([object[]]@($original))}
                'multiple'{,([object[]]@($original,$original))}
                'empty'{,([object[]]@())}
                'object'{[pscustomobject]@{value=$original}}
                'wrong-scalar'{if($original -is [string]){17}else{[string]$original}}
            }
            Set-Field $bad $field $replacement;Write-Json $path $bad
            $message='';try{Read-Definition $fixtureRoot|Out-Null}catch{$message=$_.Exception.Message}
            Check ($message -match 'must have JSON type') ('Raw transaction '+$field+' '+$kind+' was accepted: '+$message)
        }
    }
    # Raw null is valid only for an absent prior descriptor.
    $absent=New-Fixture (Join-Path $root 'absent')
    Write-Json (Join-Path $root ('absent\'+$journalName)) $absent
    Read-Definition (Join-Path $root 'absent')|Out-Null;$checks++
    foreach($field in @('old_bytes','old_sha256')){
        $bad=Copy-Value $absent;$bad.items[0].PSObject.Properties[$field].Value=[object[]]@(,$null)
        Write-Json (Join-Path $root ('absent\'+$journalName)) $bad
        $message='';try{Read-Definition (Join-Path $root 'absent')|Out-Null}catch{$message=$_.Exception.Message}
        Check (-not [string]::IsNullOrWhiteSpace($message)) ('Absent prior '+$field+' singleton null array was accepted.')
    }
    # Invoke the actual public packaging recovery path. Incomplete owned source
    # deliberately stops later tooling, after recovery has accepted or rejected
    # its serialized journal; no native compiler, tester, download or build runs.
    foreach($field in $fields){
        $case=Join-Path $root ('public-'+$field.Replace('.','-'))
        $output=Join-Path $case 'output';$project=Join-Path $case 'source'
        $bad=New-Fixture $output -Prior
        [IO.Directory]::CreateDirectory((Join-Path $project 'maintenance'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $project 'package.json'),'{}',$utf8)
        [IO.File]::WriteAllText((Join-Path $project 'maintenance\.update.lock'),'',$utf8)
        $target=if($field.StartsWith('item.')){$bad.items[0].PSObject.Properties[$field.Substring(5)].Value}else{$bad.PSObject.Properties[$field].Value}
        Set-Field $bad $field ([object[]]@($target))
        Write-Json (Join-Path $output $journalName) $bad
        $before=@{}
        foreach($file in Get-ChildItem -LiteralPath $case -Recurse -File -Force){$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
        $preference=$ErrorActionPreference
        try{
            $ErrorActionPreference='Continue'
            $text=& $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Package-Portable.ps1') -ProjectRoot $project -OutputDirectory $output 2>&1|Out-String
            $code=$LASTEXITCODE
        }finally{$ErrorActionPreference=$preference}
        Check ($code -ne 0 -and $text -match 'must have JSON type') ('Public recovery accepted '+$field+': '+$text)
        foreach($file in $before.GetEnumerator()){Check ((Test-Path -LiteralPath $file.Key) -and (Get-FileHash -LiteralPath $file.Key -Algorithm SHA256).Hash -ceq $file.Value) ('Public recovery changed evidence: '+$file.Key)}
        Check (@(Get-ChildItem -LiteralPath $case -Recurse -File -Force).Count -eq $before.Count) 'Public rejection changed file closure.'
    }
    Write-Output ('TRANSACTION_SCALAR_TYPE_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
}finally{
    $full=[IO.Path]::GetFullPath($root)
    if(-not $full.StartsWith($parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Transaction test cleanup escaped its parent.'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
$global:LASTEXITCODE=0
