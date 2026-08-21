param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference="Stop"
$source=[IO.Path]::GetFullPath($SourceDirectory).TrimEnd([char[]]@('\','/'))
if(-not(Test-Path -LiteralPath $source -PathType Container)){throw "Publish directory not found: $source"}

function Get-WixId {
    param([string]$Prefix,[string]$Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$bytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant()))}
    finally{$sha.Dispose()}
    $hex=([BitConverter]::ToString($bytes)).Replace('-','').Substring(0,24)
    return ($Prefix+$hex)
}

$doc=New-Object Xml.XmlDocument
$decl=$doc.CreateXmlDeclaration('1.0','utf-8',$null)
[void]$doc.AppendChild($decl)
$wix=$doc.CreateElement('Wix','http://wixtoolset.org/schemas/v4/wxs')
[void]$doc.AppendChild($wix)

$dirFragment=$doc.CreateElement('Fragment',$wix.NamespaceURI)
$dirRef=$doc.CreateElement('DirectoryRef',$wix.NamespaceURI)
$dirRef.SetAttribute('Id','INSTALLFOLDER')
[void]$dirFragment.AppendChild($dirRef)
[void]$wix.AppendChild($dirFragment)

$groupFragment=$doc.CreateElement('Fragment',$wix.NamespaceURI)
$group=$doc.CreateElement('ComponentGroup',$wix.NamespaceURI)
$group.SetAttribute('Id','PublishedFiles')
[void]$groupFragment.AppendChild($group)
[void]$wix.AppendChild($groupFragment)

$directoryNodes=@{'1'=$dirRef}
$files=Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object FullName
foreach($file in $files){
    $relative=$file.FullName.Substring($source.Length+1)
    $parts=$relative -split '[\\/]'
    $parent=$dirRef
    $pathKey=''

    for($i=0;$i-lt($parts.Count-1);$i++){
        $pathKey=if($pathKey){$pathKey+'\'+$parts[$i]}else{$parts[$i]}
        if(-not$directoryNodes.ContainsKey($pathKey)){
            $dir=$doc.CreateElement('Directory',$wix.NamespaceURI)
            $dir.SetAttribute('Id',(Get-WixId 'D' $pathKey))
            $dir.SetAttribute('Name',$parts[$i])
            [void]$parent.AppendChild($dir)
            $directoryNodes[$pathKey]=$dir
        }
        $parent=$directoryNodes[$pathKey]
    }

    $componentId=Get-WixId 'C' $relative
    $component=$doc.CreateElement('Component',$wix.NamespaceURI)
    $component.SetAttribute('Id',$componentId)
    $component.SetAttribute('Guid','*')
    $fileNode=$doc.CreateElement('File',$wix.NamespaceURI)
    $fileNode.SetAttribute('Id',(Get-WixId 'F' $relative))
    $fileNode.SetAttribute('Source',('$(var.PublishDir)\'+$relative))
    $fileNode.SetAttribute('KeyPath','yes')
    [void]$component.AppendChild($fileNode)
    [void]$parent.AppendChild($component)

    $ref=$doc.CreateElement('ComponentRef',$wix.NamespaceURI)
    $ref.SetAttribute('Id',$componentId)
    [void]$group.AppendChild($ref)
}

$settings=New-Object Xml.XmlWriterSettings
$settings.Indent=$true
$settings.Encoding=New-Object Text.UTF8Encoding($false)
$settings.NewLineChars="`r`n"
$writer=[Xml.XmlWriter]::Create($OutputPath,$settings)
try{$doc.Save($writer)}finally{$writer.Dispose()}
Write-Host "Harvested $($files.Count) published files: $OutputPath" -ForegroundColor Green
