# asar.ps1 — minimal, dependency-free reader for Electron ASAR archives.
# We only need to EXTRACT (Electron loads an unpacked app/ folder because the
# OnlyLoadAppFromAsar fuse is off), so no packer / integrity hashing is required.

function Read-AsarHeader {
    param([Parameter(Mandatory)][System.IO.FileStream]$Stream)
    $br = New-Object System.IO.BinaryReader($Stream)
    [void]$br.ReadUInt32()            # pickle size prefix (always 4)
    $hdrPickleSize = $br.ReadUInt32() # size of the header pickle that follows
    [void]$br.ReadUInt32()            # string pickle size
    $jsonLen = $br.ReadUInt32()       # JSON byte length
    $jsonBytes = $br.ReadBytes([int]$jsonLen)
    $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
    return [pscustomobject]@{
        Header    = ($json | ConvertFrom-Json)
        DataStart = [int64]8 + [int64]$hdrPickleSize
    }
}

function Expand-Asar {
    <#
several .NET calls; extracts every packed file. Files flagged "unpacked" live in
<asar>.unpacked and are intentionally skipped here (merge that folder afterwards).
    #>
    param(
        [Parameter(Mandatory)][string]$AsarPath,
        [Parameter(Mandatory)][string]$OutDir
    )
    $fs = [System.IO.File]::OpenRead($AsarPath)
    try {
        $parsed = Read-AsarHeader -Stream $fs
        $dataStart = $parsed.DataStart
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

        $stack = [System.Collections.Stack]::new()
        $stack.Push([pscustomobject]@{ Node = $parsed.Header; Dir = $OutDir })
        $count = 0
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            $node = $frame.Node
            if (-not ($node.PSObject.Properties.Name -contains 'files')) { continue }
            foreach ($prop in $node.files.PSObject.Properties) {
                $name = $prop.Name
                $child = $prop.Value
                $path = Join-Path $frame.Dir $name
                $props = $child.PSObject.Properties.Name
                if ($props -contains 'files') {
                    New-Item -ItemType Directory -Force -Path $path | Out-Null
                    $stack.Push([pscustomobject]@{ Node = $child; Dir = $path })
                }
                elseif ($props -contains 'link') {
                    # in-archive symlink — not used by the Codex renderer; skip.
                }
                else {
                    if (($props -contains 'unpacked') -and $child.unpacked) { continue }
                    $size = [int]$child.size
                    $offset = [int64]$child.offset
                    $fs.Seek($dataStart + $offset, 'Begin') | Out-Null
                    $buf = New-Object byte[] $size
                    $read = 0
                    while ($read -lt $size) {
                        $r = $fs.Read($buf, $read, $size - $read)
                        if ($r -le 0) { break }
                        $read += $r
                    }
                    [System.IO.File]::WriteAllBytes($path, $buf)
                    $count++
                }
            }
        }
        return $count
    }
    finally { $fs.Dispose() }
}
