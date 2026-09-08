# Filesystem mutation preflight. Keep ASCII for Windows PowerShell 5.1.
# These checks reject existing redirects. They do not claim to prevent a
# concurrent same-user attacker from replacing an ancestor after the check.
function Assert-RtlSafePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Tree)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\') -or $full.Substring(2).Contains(':')) {
        throw '[SAFETY] Device, network and alternate-stream mutation paths are not supported.'
    }
    $cursor = $full
    while ($cursor) {
        try { $attributes = [IO.File]::GetAttributes($cursor) }
        catch [IO.FileNotFoundException] { $attributes = $null }
        catch [IO.DirectoryNotFoundException] { $attributes = $null }
        if ($null -ne $attributes) {
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "[SAFETY] Reparse point in mutation path: $cursor" }
            if (-not ($attributes -band [IO.FileAttributes]::Directory)) { Assert-RtlSingleLink -Path $cursor }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if ($Tree -and [IO.Directory]::Exists($full)) {
        # Deliberately enumerate only one level at a time, checking before descent.
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($full)) { Assert-RtlSafePath -Path $child -Tree }
    }
}

function Assert-RtlSingleLink {
    param([string]$Path)
    if (-not ('DesktopRtl.PathInfo' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DesktopRtl {
  public static class PathInfo {
    [StructLayout(LayoutKind.Sequential)] struct Info {
      public uint attr, ctLow, ctHigh, atLow, atHigh, wtLow, wtHigh;
      public uint volume, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share,
      IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
    public static uint Links(string path) {
      using (var file = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
        Info info;
        if (file.IsInvalid || !GetFileInformationByHandle(file, out info))
          throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return info.links;
      }
    }
  }
}
'@
    }
    if ([DesktopRtl.PathInfo]::Links($Path) -ne 1) { throw "[SAFETY] Hardlinked mutation file: $Path" }
}

function Get-RtlSafePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Tree)
    Assert-RtlSafePath -Path $Path -Tree:$Tree
    return $Path
}

function New-RtlSafeTempFile {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('rtl-' + [guid]::NewGuid().ToString('N') + '.tmp')
    Assert-RtlSafePath -Path $path
    $file = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
    $file.Dispose()
    return $path
}

function Remove-RtlSafeItem {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Position=0)][string[]]$Path, [string[]]$LiteralPath, [switch]$Recurse, [switch]$Force)
    $targets = if ($LiteralPath) { $LiteralPath } else { $Path }
    foreach ($target in $targets) { Assert-RtlSafePath -Path $target -Tree:$Recurse }
    Remove-Item @PSBoundParameters
}

function Copy-RtlSafeItem {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$Path, [string]$LiteralPath,
        [Parameter(Position=1)][string]$Destination, [switch]$Recurse, [switch]$Force)
    Assert-RtlSafePath -Path $Destination -Tree
    # Resolve read-only source roots (Herdr uses a directory symlink). Reject
    # descendant links so recursive copy cannot introduce redirects into staging.
    $sources = if ($LiteralPath) { Get-Item -LiteralPath $LiteralPath -Force } else { Get-Item -Path $Path -Force }
    foreach ($source in $sources) {
        if ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "[SAFETY] Linked copy source entry: $($source.FullName)" }
        if ($source.PSIsContainer) {
            Assert-RtlCopySourceTree -Path $source.FullName
        }
    }
    Copy-Item @PSBoundParameters
}

function Assert-RtlCopySourceTree {
    param([string]$Path)
    foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
        $attributes = [IO.File]::GetAttributes($child)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "[SAFETY] Linked copy source descendant: $child" }
        if ($attributes -band [IO.FileAttributes]::Directory) { Assert-RtlCopySourceTree -Path $child }
    }
}

function Rename-RtlSafeItem {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$LiteralPath, [Parameter(Position=1)][string]$NewName, [switch]$Force)
    Assert-RtlSafePath -Path $LiteralPath -Tree
    Assert-RtlSafePath -Path (Join-Path (Split-Path $LiteralPath -Parent) $NewName) -Tree
    Rename-Item @PSBoundParameters
}
