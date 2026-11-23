param([Parameter(Mandatory=$true)][string]$DestinationDirectory)
$ErrorActionPreference='Stop'
$destination=[IO.Path]::GetFullPath($DestinationDirectory)
New-Item -ItemType Directory -Force -Path $destination | Out-Null
foreach($name in @('GeneralUser-GS.sf2','TimGM6mb.sf2')) {
    $target=Join-Path $destination $name
    if(-not (Test-Path -LiteralPath $target)) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target
    }
}
Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'LICENSE.*' | Copy-Item -Destination $destination
$fluid=Join-Path $destination 'FluidR3_GM.sf2'
if(Test-Path -LiteralPath $fluid) { return }
Add-Type -AssemblyName System.IO.Compression
if(-not ('AudioSoundFontPackage' -as [type])) {
Add-Type -ReferencedAssemblies System.IO.Compression -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
public static class AudioSoundFontPackage {
    static uint U32(byte[] data, int p) { return BitConverter.ToUInt32(data, p); }
    static string Tag(byte[] data, int p) { return Encoding.ASCII.GetString(data, p, 4); }
    static void Restore(byte[] data, int start, int end, int depth, bool samples) {
        if(depth > 3) throw new InvalidDataException("Invalid SoundFont nesting");
        int p=start;
        while(p < end) {
            if(end-p < 8) throw new InvalidDataException("Invalid SoundFont chunk");
            string tag=Tag(data,p); uint size=U32(data,p+4); p+=8;
            if(size > end-p) throw new InvalidDataException("Invalid SoundFont size");
            int n=(int)size;
            if(tag == "LIST") {
                if(n < 4) throw new InvalidDataException("Invalid SoundFont LIST");
                Restore(data,p+4,p+n,depth+1,Tag(data,p)=="sdta");
            } else if(samples && tag == "smpl") {
                if((n & 1)!=0) throw new InvalidDataException("Invalid SoundFont PCM");
                int previous=0;
                for(int i=p;i<p+n;i+=2) {
                    previous=(previous+data[i]+(data[i+1]<<8)) & 65535;
                    data[i]=(byte)previous; data[i+1]=(byte)(previous>>8);
                }
            }
            p+=n+(n & 1);
            if(p > end) throw new InvalidDataException("Invalid SoundFont padding");
        }
    }
    public static void Expand(string first, string second, string output) {
        using(var packed=new MemoryStream()) {
            using(var input=File.OpenRead(first)) input.CopyTo(packed);
            using(var input=File.OpenRead(second)) input.CopyTo(packed);
            packed.Position=0;
            using(var zip=new ZipArchive(packed,ZipArchiveMode.Read)) {
                if(zip.Entries.Count!=1 || zip.Entries[0].FullName!="FluidR3_GM.sf2d" ||
                   zip.Entries[0].Length<12 || zip.Entries[0].Length>256*1024*1024)
                    throw new InvalidDataException("Invalid SoundFont package");
                byte[] data;
                using(var decoded=new MemoryStream()) {
                    using(var input=zip.Entries[0].Open()) input.CopyTo(decoded);
                    data=decoded.ToArray();
                }
                if(Tag(data,0)!="RIFF" || Tag(data,8)!="sfbk" || U32(data,4)+8L!=data.Length)
                    throw new InvalidDataException("Invalid SoundFont header");
                Restore(data,12,data.Length,0,false);
                File.WriteAllBytes(output,data);
            }
        }
    }
}
'@
}
$temporary=Join-Path $destination ('FluidR3_GM.'+[Guid]::NewGuid().ToString('N')+'.tmp')
try {
    [AudioSoundFontPackage]::Expand((Join-Path $PSScriptRoot 'FluidR3_GM.zip.001'),(Join-Path $PSScriptRoot 'FluidR3_GM.zip.002'),$temporary)
    $hash=[Security.Cryptography.SHA256]::Create()
    $inputStream=[IO.File]::OpenRead($temporary)
    try {
        $digest=[BitConverter]::ToString($hash.ComputeHash($inputStream)).Replace('-','')
        if($digest -ne '74594e8f4250680adf590507a306655a299935343583256f3b722c48a1bc1cb0') { throw 'SoundFont checksum mismatch' }
    } finally { $inputStream.Dispose(); $hash.Dispose() }
    Move-Item -LiteralPath $temporary -Destination $fluid
} finally {
    if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
