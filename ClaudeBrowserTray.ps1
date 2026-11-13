# ClaudeBrowserTray.ps1
# Tray tool: lists every browser profile that has the Claude in Chrome extension,
# with its Claude display name, browser profile name, and bridge deviceId.
# Click an entry to copy a ready-to-paste "use this browser" line for Claude.
#
#   powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1            (run tray)
#   powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1 -Dump      (print table, no tray)
#   powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1 -Install   (start with Windows + run now)
#   powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1 -Uninstall (remove startup shortcut)
#
# Read-only. Reads only keys starting with "bridge" from the extension's storage.
param([switch]$Dump, [switch]$Install, [switch]$Uninstall)

$ExtId = 'fcoeoabgfenejglbffodgkkbkcdhcgfn'
$Roots = [ordered]@{
    'Chrome'      = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    'Chrome Beta' = "$env:LOCALAPPDATA\Google\Chrome Beta\User Data"
    'Edge'        = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    'Brave'       = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    'Island'      = "$env:LOCALAPPDATA\Island\Island\User Data"
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class LdbRead {
  class Ent { public ulong Seq; public string Val; }
  static byte[] ReadAll(string path) {
    using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
      var b = new byte[fs.Length]; int o = 0;
      while (o < b.Length) { int n = fs.Read(b, o, b.Length - o); if (n <= 0) break; o += n; }
      return b;
    }
  }
  static ulong Varint(byte[] b, ref int p) {
    ulong r = 0; int s = 0;
    while (true) { byte c = b[p++]; r |= (ulong)(c & 0x7f) << s; if ((c & 0x80) == 0) break; s += 7; }
    return r;
  }
  static byte[] Unsnappy(byte[] src, int off, int len) {
    int p = off; int end = off + len; int ulen = (int)Varint(src, ref p);
    var dst = new byte[ulen]; int d = 0;
    while (p < end) {
      int tag = src[p++]; int type = tag & 3;
      if (type == 0) {
        int l = tag >> 2;
        if (l >= 60) { int nb = l - 59; l = 0; for (int i = 0; i < nb; i++) l |= src[p++] << (8 * i); }
        l += 1; Buffer.BlockCopy(src, p, dst, d, l); p += l; d += l;
      } else {
        int l, o;
        if (type == 1) { l = ((tag >> 2) & 7) + 4; o = ((tag >> 5) << 8) | src[p++]; }
        else if (type == 2) { l = (tag >> 2) + 1; o = src[p] | (src[p + 1] << 8); p += 2; }
        else { l = (tag >> 2) + 1; o = src[p] | (src[p + 1] << 8) | (src[p + 2] << 16) | (src[p + 3] << 24); p += 4; }
        for (int i = 0; i < l; i++) { dst[d] = dst[d - o]; d++; }
      }
    }
    return dst;
  }
  static byte[] Block(byte[] f, int off, int size) {
    if (f[off + size] == 1) return Unsnappy(f, off, size);
    var r = new byte[size]; Buffer.BlockCopy(f, off, r, 0, size); return r;
  }
  static List<KeyValuePair<byte[], byte[]>> Entries(byte[] b) {
    var list = new List<KeyValuePair<byte[], byte[]>>();
    int n = BitConverter.ToInt32(b, b.Length - 4);
    int end = b.Length - 4 - 4 * n; int p = 0; byte[] key = new byte[0];
    while (p < end) {
      int shared = (int)Varint(b, ref p); int non = (int)Varint(b, ref p); int vl = (int)Varint(b, ref p);
      var k = new byte[shared + non];
      Buffer.BlockCopy(key, 0, k, 0, shared); Buffer.BlockCopy(b, p, k, shared, non); p += non;
      var v = new byte[vl]; Buffer.BlockCopy(b, p, v, 0, vl); p += vl;
      key = k; list.Add(new KeyValuePair<byte[], byte[]>(k, v));
    }
    return list;
  }
  static void Put(Dictionary<string, Ent> d, string prefix, byte[] k, int klen, ulong seq, bool del, byte[] v) {
    string key = Encoding.UTF8.GetString(k, 0, klen);
    if (!key.StartsWith(prefix, StringComparison.Ordinal)) return;
    Ent e;
    if (d.TryGetValue(key, out e) && e.Seq > seq) return;
    e = new Ent(); e.Seq = seq; e.Val = del ? null : Encoding.UTF8.GetString(v); d[key] = e;
  }
  static void Table(byte[] f, Dictionary<string, Ent> d, string prefix) {
    int p = f.Length - 48; Varint(f, ref p); Varint(f, ref p);
    int io = (int)Varint(f, ref p); int isz = (int)Varint(f, ref p);
    foreach (var ie in Entries(Block(f, io, isz))) {
      try {
        int q = 0; int bo = (int)Varint(ie.Value, ref q); int bs = (int)Varint(ie.Value, ref q);
        foreach (var e in Entries(Block(f, bo, bs))) {
          int kl = e.Key.Length - 8; if (kl < 0) continue;
          ulong t = BitConverter.ToUInt64(e.Key, kl);
          Put(d, prefix, e.Key, kl, t >> 8, (t & 0xff) == 0, e.Value);
        }
      } catch { }
    }
  }
  static void Batch(byte[] r, Dictionary<string, Ent> d, string prefix) {
    if (r.Length < 12) return;
    ulong seq = BitConverter.ToUInt64(r, 0); int cnt = BitConverter.ToInt32(r, 8); int p = 12;
    for (int i = 0; i < cnt && p < r.Length; i++) {
      int t = r[p++]; int kl = (int)Varint(r, ref p);
      var k = new byte[kl]; Buffer.BlockCopy(r, p, k, 0, kl); p += kl;
      var v = new byte[0];
      if (t == 1) { int vl = (int)Varint(r, ref p); v = new byte[vl]; Buffer.BlockCopy(r, p, v, 0, vl); p += vl; }
      Put(d, prefix, k, kl, seq + (ulong)i, t == 0, v);
    }
  }
  static void Log(byte[] f, Dictionary<string, Ent> d, string prefix) {
    var rec = new MemoryStream(); int p = 0;
    while (p + 7 <= f.Length) {
      int left = 32768 - (p % 32768);
      if (left < 7) { p += left; continue; }
      int len = f[p + 4] | (f[p + 5] << 8); int type = f[p + 6];
      if (type == 0 && len == 0) { p += left; continue; }
      p += 7; if (p + len > f.Length) break;
      if (type == 1 || type == 2) rec.SetLength(0);
      rec.Write(f, p, len); p += len;
      if (type == 1 || type == 4) { try { Batch(rec.ToArray(), d, prefix); } catch { } rec.SetLength(0); }
    }
  }
  public static Dictionary<string, string> Read(string dir, string prefix) {
    var d = new Dictionary<string, Ent>();
    foreach (string f in Directory.GetFiles(dir)) {
      string x = Path.GetExtension(f).ToLowerInvariant();
      try {
        if (x == ".ldb" || x == ".sst") Table(ReadAll(f), d, prefix);
        else if (x == ".log") Log(ReadAll(f), d, prefix);
      } catch { }
    }
    var r = new Dictionary<string, string>();
    foreach (var kv in d) if (kv.Value.Val != null) r[kv.Key] = kv.Value.Val;
    return r;
  }
}
'@

function Unquote([string]$json) {
    if ([string]::IsNullOrEmpty($json)) { return '' }
    try { return [string]($json | ConvertFrom-Json) } catch { return $json.Trim('"') }
}

function Get-ClaudeBrowsers {
    $out = @()
    foreach ($browser in $Roots.Keys) {
        $root = $Roots[$browser]
        if (-not (Test-Path $root)) { continue }
        $info = $null
        try { $info = (Get-Content (Join-Path $root 'Local State') -Raw -Encoding UTF8 | ConvertFrom-Json).profile.info_cache } catch { }
        foreach ($dir in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
            $store = Join-Path $dir.FullName "Local Extension Settings\$ExtId"
            if (-not (Test-Path $store)) { continue }
            $kv = [LdbRead]::Read($store, 'bridge')
            if (-not $kv.ContainsKey('bridgeDeviceId')) { continue }
            $pname = $dir.Name; $acct = ''
            if ($info -and $info.PSObject.Properties[$dir.Name]) {
                $pi = $info.PSObject.Properties[$dir.Name].Value
                if ($pi.name) { $pname = $pi.name }
                if ($pi.user_name) { $acct = $pi.user_name }
            }
            $disp = Unquote $kv['bridgeDisplayName']
            if (-not $disp) { $disp = Unquote $kv['bridgeDefaultDisplayName'] }
            $out += [pscustomobject]@{
                ClaudeName = $disp
                Browser    = $browser
                Profile    = $pname
                ProfileDir = $dir.Name
                Account    = $acct
                DeviceId   = Unquote $kv['bridgeDeviceId']
            }
        }
    }
    $dupes = $out | Group-Object DeviceId | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
    $out | ForEach-Object { $_ | Add-Member -NotePropertyName Duplicate -NotePropertyValue ($dupes -contains $_.DeviceId) -PassThru } |
        Sort-Object Browser, Profile
}

function Format-Line($b) {
    'Use the Claude in Chrome browser with deviceId {0} ("{1}" - {2} profile "{3}")' -f $b.DeviceId, $b.ClaudeName, $b.Browser, $b.Profile
}

$self = $MyInvocation.MyCommand.Path
$lnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeBrowserTray.lnk'

if ($Dump) { Get-ClaudeBrowsers | Format-Table ClaudeName, Browser, Profile, ProfileDir, DeviceId, Duplicate -AutoSize | Out-String -Width 250; return }
if ($Uninstall) { if (Test-Path $lnk) { Remove-Item $lnk }; 'Startup shortcut removed.'; return }
if ($Install) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`""
    $s.WindowStyle = 7
    $s.Description = 'Claude browser tray'
    $s.Save()
    Start-Process $s.TargetPath -ArgumentList $s.Arguments -WindowStyle Hidden
    'Installed: starts with Windows, and is running now.'
    return
}

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'ClaudeBrowserTray_SingleInstance', [ref]$created)
if (-not $created) { return }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Icon: orange dot with a white "C"
$bmp = New-Object System.Drawing.Bitmap 32, 32
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(217, 119, 87))), 1, 1, 30, 30)
$font = New-Object System.Drawing.Font 'Segoe UI', 17, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
$g.DrawString('C', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $sf)
$g.Dispose()

$script:ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$ni.Text = 'Claude browsers - click to list'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowItemToolTips = $true
$ni.ContextMenuStrip = $menu

$copy = {
    [System.Windows.Forms.Clipboard]::SetText([string]$this.Tag)
    $script:ni.ShowBalloonTip(1500, 'Copied', 'Paste it into your Claude chat.', 'Info')
}

$menu.add_Opening({
    $menu.Items.Clear()
    $list = @(Get-ClaudeBrowsers)
    $hdr = $menu.Items.Add('Claude browsers on ' + $env:COMPUTERNAME + '  (click to copy)'); $hdr.Enabled = $false
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    if ($list.Count -eq 0) { $n = $menu.Items.Add('No profiles with the Claude extension found'); $n.Enabled = $false }
    foreach ($b in $list) {
        $warn = ''; if ($b.Duplicate) { $warn = '   [!] duplicate ID' }
        $text = ('{0}   |   {1}: {2}   |   {3}{4}' -f $b.ClaudeName, $b.Browser, $b.Profile, $b.DeviceId, $warn).Replace('&', '&&')
        $it = $menu.Items.Add($text)
        $it.Tag = Format-Line $b
        $it.ToolTipText = ('{0} [{1}] {2}' -f $b.Browser, $b.ProfileDir, $b.Account)
        $it.add_Click($copy)
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $all = $menu.Items.Add('Copy full list')
    $all.Tag = (($list | ForEach-Object { '{0} | {1}: {2} | {3}' -f $_.ClaudeName, $_.Browser, $_.Profile, $_.DeviceId }) -join "`r`n") + ' '
    $all.add_Click($copy)
    $ex = $menu.Items.Add('Exit')
    $ex.add_Click({ $script:ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
    $_.Cancel = $false
})

$ni.add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $m = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($m) { [void]$m.Invoke($script:ni, $null) }
    }
})

$ni.Visible = $true
[System.Windows.Forms.Application]::Run()
$ni.Dispose(); $mutex.ReleaseMutex()
