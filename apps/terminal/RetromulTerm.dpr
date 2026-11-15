program RetromulTerm;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  Core.Platforms.Bluetooth in '..\..\source\platforms\bluetooth\Core.Platforms.Bluetooth.pas',
  Core.Platforms.Bluetooth.Windows.IO in '..\..\source\platforms\bluetooth\Core.Platforms.Bluetooth.Windows.IO.pas',
  Core.Platforms.Bluetooth.Windows in '..\..\source\platforms\bluetooth\Core.Platforms.Bluetooth.Windows.pas',
  Core.Bluetooth.Service in '..\..\source\runtime\Core.Bluetooth.Service.pas',
  J2ME.Bluetooth.Transport in '..\..\source\cores\j2me\J2ME.Bluetooth.Transport.pas',
  Core.Messaging in '..\..\source\runtime\Core.Messaging.pas',
  Core.Messaging.Types in '..\..\source\runtime\Core.Messaging.Types.pas',
  Core.Messaging.Virtual in '..\..\source\runtime\Core.Messaging.Virtual.pas',
  J2ME.Messaging in '..\..\source\cores\j2me\J2ME.Messaging.pas',
  J2ME.DateField in '..\..\source\cores\j2me\J2ME.DateField.pas',
  Java.Calendars in '..\..\source\vm\java\Java.Calendars.pas',
  Java.Dates in '..\..\source\vm\java\Java.Dates.pas',
  Java.TimeZones in '..\..\source\vm\java\Java.TimeZones.pas',
  Java.Booleans in '..\..\source\vm\java\Java.Booleans.pas',
  Java.Math in '..\..\source\vm\java\Java.Math.pas',
  Java.Characters in '..\..\source\vm\java\Java.Characters.pas',
  Java.Unicode in '..\..\source\vm\java\Java.Unicode.pas',
  Java.Writers in '..\..\source\vm\java\Java.Writers.pas',
  J2ME.Device in '..\..\source\cores\j2me\J2ME.Device.pas',
  J2ME.Nokia.OTA in '..\..\source\cores\j2me\J2ME.Nokia.OTA.pas',
  J2ME.Nokia.Sound in '..\..\source\cores\j2me\J2ME.Nokia.Sound.pas',
  J2ME.Nokia.UI in '..\..\source\cores\j2me\J2ME.Nokia.UI.pas',
  Java.Environment in '..\..\source\vm\java\Java.Environment.pas',
  Java.Builders in '..\..\source\vm\java\Java.Builders.pas',
  Java.Reflection in '..\..\source\vm\java\Java.Reflection.pas',
  J2ME.Bluetooth in '..\..\source\cores\j2me\J2ME.Bluetooth.pas',
  J2ME.Bluetooth.Data in '..\..\source\cores\j2me\J2ME.Bluetooth.Data.pas',
  Core.Bluetooth.SDP in '..\..\source\runtime\Core.Bluetooth.SDP.pas',
  Core.Bluetooth.Channel in '..\..\source\runtime\Core.Bluetooth.Channel.pas',
  Core.Bluetooth in '..\..\source\runtime\Core.Bluetooth.pas',
  Core.Bluetooth.Types in '..\..\source\runtime\Core.Bluetooth.Types.pas',
  J2ME.Network.HTTP in '..\..\source\cores\j2me\J2ME.Network.HTTP.pas',
  J2ME.Network in '..\..\source\cores\j2me\J2ME.Network.pas',
  J2ME.Form.Layout in '..\..\source\cores\j2me\J2ME.Form.Layout.pas',
  J2ME.Forms in '..\..\source\cores\j2me\J2ME.Forms.pas',
  J2ME.Item.Layout in '..\..\source\cores\j2me\J2ME.Item.Layout.pas',
  J2ME.Text in '..\..\source\cores\j2me\J2ME.Text.pas',
  J2ME.UI.Data in '..\..\source\cores\j2me\J2ME.UI.Data.pas',
  J2ME.Alert.Layout in '..\..\source\cores\j2me\J2ME.Alert.Layout.pas',
  J2ME.Items in '..\..\source\cores\j2me\J2ME.Items.pas',
  Java.Diagnostics in '..\..\source\vm\java\Java.Diagnostics.pas',
  Java.Readers in '..\..\source\vm\java\Java.Readers.pas',
  Java.Hashtable in '..\..\source\vm\java\Java.Hashtable.pas',
  Java.Numbers in '..\..\source\vm\java\Java.Numbers.pas',
  Java.Collections in '..\..\source\vm\java\Java.Collections.pas',
  Java.Timers in '..\..\source\vm\java\Java.Timers.pas',
  Media.Raster.Shapes in '..\..\source\media\image\Media.Raster.Shapes.pas',
  J2ME.LCDUI in '..\..\source\cores\j2me\J2ME.LCDUI.pas',
  J2ME.RMS in '..\..\source\cores\j2me\J2ME.RMS.pas',
  J2ME.RMS.Store in '..\..\source\cores\j2me\J2ME.RMS.Store.pas',
  J2ME.Media in '..\..\source\cores\j2me\J2ME.Media.pas',
  J2ME.Effects in '..\..\source\cores\j2me\J2ME.Effects.pas',
  J2ME.Siemens.Game in '..\..\source\cores\j2me\J2ME.Siemens.Game.pas',
  J2ME.Siemens.Graphics in '..\..\source\cores\j2me\J2ME.Siemens.Graphics.pas',
  J2ME.Resources in '..\..\source\cores\j2me\J2ME.Resources.pas',
  Core.Platforms.J2ME.Playback in '..\..\source\platforms\j2me\Core.Platforms.J2ME.Playback.pas',
  RetroTune.Decoder in '..\..\source\music\decoders\RetroTune.Decoder.pas',
  RetroTune.Decoder.WAV in '..\..\source\music\decoders\RetroTune.Decoder.WAV.pas',
  RetroTune.Decoder.MIDI in '..\..\source\music\decoders\RetroTune.Decoder.MIDI.pas',
  RetroTune.Binary in '..\..\source\music\common\RetroTune.Binary.pas',
  RetroTune.SoundFontCatalog in '..\..\source\music\common\RetroTune.SoundFontCatalog.pas',
  RetroTune.SoundFont in '..\..\source\music\synthesis\RetroTune.SoundFont.pas',
  Java.Charsets in '..\..\source\vm\java\Java.Charsets.pas',
  Java.Strings in '..\..\source\vm\java\Java.Strings.pas',
  J2ME.Game.Layers in '..\..\source\cores\j2me\J2ME.Game.Layers.pas',
  J2ME.GameCanvas in '..\..\source\cores\j2me\J2ME.GameCanvas.pas',
  J2ME.Font in '..\..\source\cores\j2me\J2ME.Font.pas',
  Media.Font.Hershey in '..\..\source\media\image\Media.Font.Hershey.pas',
  Media.Font.Bitmap in '..\..\source\media\image\Media.Font.Bitmap.pas',
  J2ME.Image in '..\..\source\cores\j2me\J2ME.Image.pas',
  Media.Image.PNG in '..\..\source\media\image\Media.Image.PNG.pas',
  J2ME.Graphics in '..\..\source\cores\j2me\J2ME.Graphics.pas',
  Java.Classes in '..\..\source\vm\java\Java.Classes.pas',
  Java.IO in '..\..\source\vm\java\Java.IO.pas',
  Java.Random in '..\..\source\vm\java\Java.Random.pas',
  JVM.Linker in '..\..\source\vm\jvm\JVM.Linker.pas',
  JVM.Verifier in '..\..\source\vm\jvm\JVM.Verifier.pas',
  JVM.Threading in '..\..\source\vm\jvm\JVM.Threading.pas',
  JVM.Bytecode in '..\..\source\vm\jvm\JVM.Bytecode.pas',
  Java.Bootstrap in '..\..\source\vm\java\Java.Bootstrap.pas',
  JVM.ClassFile in '..\..\source\vm\jvm\JVM.ClassFile.pas',
  JVM.Runtime in '..\..\source\vm\jvm\JVM.Runtime.pas',
  JVM.Types in '..\..\source\vm\jvm\JVM.Types.pas',
  J2ME.Runtime in '..\..\source\cores\j2me\J2ME.Runtime.pas',
  J2ME.Suite in '..\..\source\cores\j2me\J2ME.Suite.pas',
  Core.Platforms.J2ME.Adapter in '..\..\source\platforms\j2me\Core.Platforms.J2ME.Adapter.pas',
  RM.Platforms.J2ME in '..\..\source\platforms\j2me\RM.Platforms.J2ME.pas',
  S32.Protection in '..\..\source\cores\system32\S32.Protection.pas',
  S32.BusProtection in '..\..\source\cores\system32\S32.BusProtection.pas',
  S32.CD in '..\..\source\cores\system32\S32.CD.pas',
  S32.DriveBoard in '..\..\source\cores\system32\S32.DriveBoard.pas',
  S32.IRQ in '..\..\source\cores\system32\S32.IRQ.pas',
  HW.V60 in '..\..\source\hardware\cpu\HW.V60.pas',
  S32.Cartridge in '..\..\source\cores\system32\S32.Cartridge.pas',
  S32.Console in '..\..\source\cores\system32\S32.Console.pas',
  S32.RomSets in '..\..\source\cores\system32\S32.RomSets.pas',
  S32.Sound in '..\..\source\cores\system32\S32.Sound.pas',
  S32.Video in '..\..\source\cores\system32\S32.Video.pas',
  Core.Platforms.System32.Adapter in '..\..\source\platforms\system32\Core.Platforms.System32.Adapter.pas',
  RM.Platforms.System32.Gamepads in '..\..\source\platforms\system32\RM.Platforms.System32.Gamepads.pas',
  RM.Platforms.System32 in '..\..\source\platforms\system32\RM.Platforms.System32.pas',
  S16.Crypto in '..\..\source\cores\system16\S16.Crypto.pas',
  S16.I8751 in '..\..\source\cores\system16\S16.I8751.pas',
  S16.UPD7751 in '..\..\source\cores\system16\S16.UPD7751.pas',
  S16.Cartridge in '..\..\source\cores\system16\S16.Cartridge.pas',
  S16.Console in '..\..\source\cores\system16\S16.Console.pas',
  S16.RomSets in '..\..\source\cores\system16\S16.RomSets.pas',
  S16.Sound in '..\..\source\cores\system16\S16.Sound.pas',
  S16.Video in '..\..\source\cores\system16\S16.Video.pas',
  Core.Platforms.System16.Adapter in '..\..\source\platforms\system16\Core.Platforms.System16.Adapter.pas',
  RM.Platforms.System16.Gamepads in '..\..\source\platforms\system16\RM.Platforms.System16.Gamepads.pas',
  RM.Platforms.System16 in '..\..\source\platforms\system16\RM.Platforms.System16.pas',
  A7800.Cartridge in '..\..\source\cores\at7800\A7800.Cartridge.pas',
  A7800.Console in '..\..\source\cores\at7800\A7800.Console.pas',
  A7800.Emulation in '..\..\source\cores\at7800\A7800.Emulation.pas',
  A7800.MARIA in '..\..\source\cores\at7800\A7800.MARIA.pas',
  Core.Platforms.Atari7800.Adapter in '..\..\source\platforms\at7800\Core.Platforms.Atari7800.Adapter.pas',
  RM.Platforms.Atari7800.Gamepads in '..\..\source\platforms\at7800\RM.Platforms.Atari7800.Gamepads.pas',
  RM.Platforms.Atari7800 in '..\..\source\platforms\at7800\RM.Platforms.Atari7800.pas',
  RM.Platforms.Atari7800.Settings in '..\..\source\platforms\at7800\RM.Platforms.Atari7800.Settings.pas',
  Jaguar.CD in '..\..\source\cores\jaguar\Jaguar.CD.pas',
  Jaguar.Blitter in '..\..\source\cores\jaguar\Jaguar.Blitter.pas',
  Jaguar.Console in '..\..\source\cores\jaguar\Jaguar.Console.pas',
  Jaguar.Emulation in '..\..\source\cores\jaguar\Jaguar.Emulation.pas',
  Jaguar.Firmware in '..\..\source\cores\jaguar\Jaguar.Firmware.pas',
  Jaguar.Jerry in '..\..\source\cores\jaguar\Jaguar.Jerry.pas',
  Jaguar.RISC in '..\..\source\cores\jaguar\Jaguar.RISC.pas',
  Jaguar.Video in '..\..\source\cores\jaguar\Jaguar.Video.pas',
  Core.Platforms.Jaguar.Adapter in '..\..\source\platforms\jaguar\Core.Platforms.Jaguar.Adapter.pas',
  RM.Platforms.Jaguar.Gamepads in '..\..\source\platforms\jaguar\RM.Platforms.Jaguar.Gamepads.pas',
  RM.Platforms.Jaguar.Input in '..\..\source\platforms\jaguar\RM.Platforms.Jaguar.Input.pas',
  RM.Platforms.Jaguar in '..\..\source\platforms\jaguar\RM.Platforms.Jaguar.pas',
  RM.Platforms.Jaguar.Settings in '..\..\source\platforms\jaguar\RM.Platforms.Jaguar.Settings.pas',
  HW.V30MZ in '..\..\source\hardware\cpu\HW.V30MZ.pas',
  WS.Cartridge in '..\..\source\cores\ws\WS.Cartridge.pas',
  WS.Console in '..\..\source\cores\ws\WS.Console.pas',
  WS.EEPROM in '..\..\source\cores\ws\WS.EEPROM.pas',
  WS.Emulation in '..\..\source\cores\ws\WS.Emulation.pas',
  WS.Sound in '..\..\source\cores\ws\WS.Sound.pas',
  WS.Types in '..\..\source\cores\ws\WS.Types.pas',
  WS.Video in '..\..\source\cores\ws\WS.Video.pas',
  Core.Platforms.WS.Adapter in '..\..\source\platforms\ws\Core.Platforms.WS.Adapter.pas',
  RM.Platforms.WS.Gamepads in '..\..\source\platforms\ws\RM.Platforms.WS.Gamepads.pas',
  RM.Platforms.WS.Help in '..\..\source\platforms\ws\RM.Platforms.WS.Help.pas',
  RM.Platforms.WS in '..\..\source\platforms\ws\RM.Platforms.WS.pas',
  RM.Platforms.WS.Settings in '..\..\source\platforms\ws\RM.Platforms.WS.Settings.pas',
  HW.EEPROM93Cxx in '..\..\source\hardware\HW.EEPROM93Cxx.pas',
  HW.W65C02 in '..\..\source\hardware\cpu\HW.W65C02.pas',
  Lynx.Cartridge in '..\..\source\cores\lynx\Lynx.Cartridge.pas',
  Lynx.Console in '..\..\source\cores\lynx\Lynx.Console.pas',
  Lynx.Emulation in '..\..\source\cores\lynx\Lynx.Emulation.pas',
  Lynx.Firmware in '..\..\source\cores\lynx\Lynx.Firmware.pas',
  Lynx.Mikey in '..\..\source\cores\lynx\Lynx.Mikey.pas',
  Lynx.Suzy in '..\..\source\cores\lynx\Lynx.Suzy.pas',
  Lynx.Types in '..\..\source\cores\lynx\Lynx.Types.pas',
  Core.Platforms.Lynx.Adapter in '..\..\source\platforms\lynx\Core.Platforms.Lynx.Adapter.pas',
  RM.Platforms.Lynx in '..\..\source\platforms\lynx\RM.Platforms.Lynx.pas',
  RM.Platforms.Lynx.Settings in '..\..\source\platforms\lynx\RM.Platforms.Lynx.Settings.pas',
  RM.Platforms.Lynx.Gamepads in '..\..\source\platforms\lynx\RM.Platforms.Lynx.Gamepads.pas',
  NDS.BIOS in '..\..\source\cores\nds\NDS.BIOS.pas',
  NDS.RTC in '..\..\source\cores\nds\NDS.RTC.pas',
  NDS.Geometry in '..\..\source\cores\nds\NDS.Geometry.pas',
  RM.Platforms.NDS.Settings in '..\..\source\platforms\nds\RM.Platforms.NDS.Settings.pas',
  RM.Platforms.NDS in '..\..\source\platforms\nds\RM.Platforms.NDS.pas',
  RM.Platforms.NDS.Input in '..\..\source\platforms\nds\RM.Platforms.NDS.Input.pas',
  Core.Platforms.NDS.Adapter in '..\..\source\platforms\nds\Core.Platforms.NDS.Adapter.pas',
  Core.Platforms.NDS.Display in '..\..\source\platforms\nds\Core.Platforms.NDS.Display.pas',
  NDS.Video in '..\..\source\cores\nds\NDS.Video.pas',
  NDS.Sound in '..\..\source\cores\nds\NDS.Sound.pas',
  NDS.Console in '..\..\source\cores\nds\NDS.Console.pas',
  NDS.Cartridge in '..\..\source\cores\nds\NDS.Cartridge.pas',
  A5200.ANTIC in '..\..\source\cores\at5200\A5200.ANTIC.pas',
  A5200.Arithmetic in '..\..\source\cores\at5200\A5200.Arithmetic.pas',
  A5200.ASAP.CPU in '..\..\source\cores\at5200\A5200.ASAP.CPU.pas',
  A5200.ASAP.Info in '..\..\source\cores\at5200\A5200.ASAP.Info.pas',
  A5200.ASAP in '..\..\source\cores\at5200\A5200.ASAP.pas',
  A5200.ASAP.Types in '..\..\source\cores\at5200\A5200.ASAP.Types.pas',
  A5200.Audio.MPT in '..\..\source\cores\at5200\A5200.Audio.MPT.pas',
  A5200.AudioMachine in '..\..\source\cores\at5200\A5200.AudioMachine.pas',
  A5200.Cartridge in '..\..\source\cores\at5200\A5200.Cartridge.pas',
  A5200.Console in '..\..\source\cores\at5200\A5200.Console.pas',
  A5200.Controller in '..\..\source\cores\at5200\A5200.Controller.pas',
  A5200.CPU in '..\..\source\cores\at5200\A5200.CPU.pas',
  A5200.Emulation in '..\..\source\cores\at5200\A5200.Emulation.pas',
  A5200.Firmware in '..\..\source\cores\at5200\A5200.Firmware.pas',
  A5200.GTIA in '..\..\source\cores\at5200\A5200.GTIA.pas',
  A5200.POKEY.Engine in '..\..\source\cores\at5200\A5200.POKEY.Engine.pas',
  A5200.POKEY in '..\..\source\cores\at5200\A5200.POKEY.pas',
  A5200.POKEY.Types in '..\..\source\cores\at5200\A5200.POKEY.Types.pas',
  A5200.Types in '..\..\source\cores\at5200\A5200.Types.pas',
  Core.Platforms.Atari5200.Adapter in '..\..\source\platforms\at5200\Core.Platforms.Atari5200.Adapter.pas',
  RM.Platforms.Atari5200.Gamepads in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.Gamepads.pas',
  RM.Platforms.Atari5200.Input in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.Input.pas',
  RM.Platforms.Atari5200 in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.pas',
  RM.Platforms.Atari5200.Settings in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.Settings.pas',
  A2600.Types in '..\..\source\cores\at2600\A2600.Types.pas',
  A2600.CPU in '..\..\source\cores\at2600\A2600.CPU.pas',
  A2600.Cartridge in '..\..\source\cores\at2600\A2600.Cartridge.pas',
  A2600.DPC in '..\..\source\cores\at2600\A2600.DPC.pas',
  A2600.Supercharger in '..\..\source\cores\at2600\A2600.Supercharger.pas',
  A2600.Controller in '..\..\source\cores\at2600\A2600.Controller.pas',
  A2600.Paddle in '..\..\source\cores\at2600\A2600.Paddle.pas',
  A2600.RIOT in '..\..\source\cores\at2600\A2600.RIOT.pas',
  A2600.Palette in '..\..\source\cores\at2600\A2600.Palette.pas',
  A2600.TIA in '..\..\source\cores\at2600\A2600.TIA.pas',
  A2600.State in '..\..\source\cores\at2600\A2600.State.pas',
  RM.Platforms.Atari2600.Settings in '..\..\source\platforms\at2600\RM.Platforms.Atari2600.Settings.pas',
  A2600.Console in '..\..\source\cores\at2600\A2600.Console.pas',
  A2600.Emulation in '..\..\source\cores\at2600\A2600.Emulation.pas',
  Core.Platforms.Atari2600.Adapter in '..\..\source\platforms\at2600\Core.Platforms.Atari2600.Adapter.pas',
  RM.Platforms.Atari2600 in '..\..\source\platforms\at2600\RM.Platforms.Atari2600.pas',
  RM.Platforms.Atari2600.Gamepads in '..\..\source\platforms\at2600\RM.Platforms.Atari2600.Gamepads.pas',
  CV.Audio in '..\..\source\cores\colecovision\CV.Audio.pas',
  CV.Controller in '..\..\source\cores\colecovision\CV.Controller.pas',
  CV.F18A.GPU in '..\..\source\cores\colecovision\CV.F18A.GPU.pas',
  CV.F18A in '..\..\source\cores\colecovision\CV.F18A.pas',
  CV.SSTFlash in '..\..\source\cores\colecovision\CV.SSTFlash.pas',
  CV.Cartridge in '..\..\source\cores\colecovision\CV.Cartridge.pas',
  CV.Console in '..\..\source\cores\colecovision\CV.Console.pas',
  CV.Emulation in '..\..\source\cores\colecovision\CV.Emulation.pas',
  CV.Firmware in '..\..\source\cores\colecovision\CV.Firmware.pas',
  Core.Platforms.ColecoVision.Adapter in '..\..\source\platforms\colecovision\Core.Platforms.ColecoVision.Adapter.pas',
  RM.Platforms.ColecoVision.Gamepads in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.Gamepads.pas',
  RM.Platforms.ColecoVision.Input in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.Input.pas',
  RM.Platforms.ColecoVision in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.pas',
  RM.Platforms.ColecoVision.Settings in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.Settings.pas',
  RetroMul.Platforms in '..\retromul\RetroMul.Platforms.pas',
  HW.Sound.Y8950 in '..\..\source\hardware\audio\HW.Sound.Y8950.pas',

  HW.ARM in '..\..\source\hardware\cpu\HW.ARM.pas',
  Audio.ATRAC3.Decoder in '..\..\source\media\audio\atrac3\Audio.ATRAC3.Decoder.pas',
  Audio.ATRAC3 in '..\..\source\media\audio\atrac3\Audio.ATRAC3.pas',
  Core.Bitstream in '..\..\source\media\Core.Bitstream.pas',
  Video.AVC.Bitstream in '..\..\source\media\video\avc\Video.AVC.Bitstream.pas',
  Video.AVC.H264.CABAC in '..\..\source\media\video\avc\Video.AVC.H264.CABAC.pas',
  Video.AVC.H264.DSP in '..\..\source\media\video\avc\Video.AVC.H264.DSP.pas',
  Video.AVC.H264 in '..\..\source\media\video\avc\Video.AVC.H264.pas',
  Video.AVC.H264.Syntax in '..\..\source\media\video\avc\Video.AVC.H264.Syntax.pas',
  Video.AVC.H264.Tables in '..\..\source\media\video\avc\Video.AVC.H264.Tables.pas',
  Video.AVC.Types in '..\..\source\media\video\avc\Video.AVC.Types.pas',
  FMXAudio.AAC.ER in '..\..\source\media\audio\aac\FMXAudio.AAC.ER.pas',
  FMXAudio.AAC.LD in '..\..\source\media\audio\aac\FMXAudio.AAC.LD.pas',
  FMXAudio.AAC in '..\..\source\media\audio\aac\FMXAudio.AAC.pas',
  FMXAudio.AAC.PS in '..\..\source\media\audio\aac\FMXAudio.AAC.PS.pas',
  FMXAudio.AAC.SBR in '..\..\source\media\audio\aac\FMXAudio.AAC.SBR.pas',
  FMXAudio.AAC.SSR in '..\..\source\media\audio\aac\FMXAudio.AAC.SSR.pas',
  FMXAudio.AAC.Tables in '..\..\source\media\audio\aac\FMXAudio.AAC.Tables.pas',
  FMXAudio.AAC.USAC.LPC in '..\..\source\media\audio\aac\FMXAudio.AAC.USAC.LPC.pas',
  FMXAudio.AAC.USAC.LPD in '..\..\source\media\audio\aac\FMXAudio.AAC.USAC.LPD.pas',
  FMXAudio.AAC.USAC in '..\..\source\media\audio\aac\FMXAudio.AAC.USAC.pas',
  FMXAudio.Bitstream in '..\..\source\media\audio\common\FMXAudio.Bitstream.pas',
  FMXAudio.Transform in '..\..\source\media\audio\common\FMXAudio.Transform.pas',
  FMXAudio.Types in '..\..\source\media\common\FMXAudio.Types.pas',
  Audio.ATRAC3Plus in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.pas',
  Audio.ATRAC3Plus.Decoder in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.Decoder.pas',
  Audio.ATRAC3Plus.Primitives in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.Primitives.pas',
  Audio.ATRAC3Plus.Tables in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.Tables.pas',
  System.SysUtils,
  System.Classes, System.UITypes,
  Winapi.Windows,
  FMX.Graphics,
  Core.Emulation,
  Core.EmulatorFactory, Core.PlatformServices,
  Core.Storage,
  Core.Platforms in '..\..\source\runtime\Core.Platforms.pas',
  Retromul.Terminal in 'Retromul.Terminal.pas';

var
  Running: Boolean;
  FEmulation: IEmulationCore;
  FUserPaused: Boolean;
  FKeysDown: array[0..255] of Boolean;
  FEmulationFaulted: Boolean;
  FRomDisplayName: string;

procedure SetStatus(const Text: string);
begin
  TRetromulTerminal.SetTitle('RetromulTerm - ' + Text);
end;

procedure StopOnError;
begin
  FEmulationFaulted := True;
  if FEmulation <> nil then
    FEmulation.Pause;
  SetStatus('Stopped after error - ' + FRomDisplayName);
end;

procedure LoadRom(const FileName: string; const DisplayName: string);
begin
  // Construct first: an invalid ROM leaves the current worker running.
  var NewEmulation: IEmulationCore;
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try NewEmulation := CreateEmulationCore(Stream, Storage, FileName);
  finally Stream.Free; end;
  try
    if FEmulation <> nil then
      FEmulation.Stop;
  except
    NewEmulation := nil;
    raise;
  end;
  FEmulation := nil;
  FEmulation := NewEmulation;
  FUserPaused := False;
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  FRomDisplayName := DisplayName;
  if FRomDisplayName = '' then
    FRomDisplayName := ExtractFileName(FileName);
  try
    TRetromulTerminal.Clear;
    FEmulationFaulted := False;
    FEmulation.Start;
    SetStatus(FEmulation.Name + ' - ' + FRomDisplayName);
  except
    StopOnError;
    raise;
  end;
end;

procedure UpdateFrame;
begin
  if FEmulation = nil then
    Exit;
  var Frame: TEmulatorFrame;
  var NewFrame := FEmulation.TryGetFrame(Frame);
  var ErrorText := FEmulation.TakeError;
  if (ErrorText <> '') and not FEmulationFaulted then
  begin
    StopOnError;
    raise Exception.Create(ErrorText);
  end;
  if not FEmulationFaulted and NewFrame then
  begin
    SetStatus(Format('%s - %.1f FPS', [FEmulation.Name, Frame.FramesPerSecond]));
  end;
  if not NewFrame then
    Exit;

  TRetromulTerminal.DrawFrame(Frame, TTerminalRenderMode.trmAscii, TRetromulTerminal.Width, TRetromulTerminal.Height - 2);
end;

begin
  TRetromulTerminal.Initialize;
  try
    TRetromulTerminal.SetTitle('RetroMul');
    TRetromulTerminal.Clear;
    var RomName := ParamStr(1);

    if RomName.IsEmpty then
    begin
      Writeln('Set file name as param 1');
      Exit;
    end;
    LoadRom(RomName, '');

    Running := True;
    while Running do
    begin
      try
        UpdateFrame;
      except
        StopOnError;
        raise;
      end;

      var InputPolicy := TerminalInputPolicy(FEmulation);
      if InputPolicy.AllKeys then
      begin
        for var Code := 1 to 255 do
        begin
          var Down := TRetromulTerminal.IsKeyDown(Code);
          if Down <> FKeysDown[Code] then FEmulation.SetKeyState(Code, Down);
          FKeysDown[Code] := Down;
        end;
      end
      else
      begin
        FEmulation.SetKeyState(VK_LEFT, TRetromulTerminal.IsKeyDown(VK_LEFT));
        FEmulation.SetKeyState(VK_RIGHT, TRetromulTerminal.IsKeyDown(VK_RIGHT));
        FEmulation.SetKeyState(VK_UP, TRetromulTerminal.IsKeyDown(VK_UP));
        FEmulation.SetKeyState(VK_DOWN, TRetromulTerminal.IsKeyDown(VK_DOWN));
        FEmulation.SetKeyState(vkZ, TRetromulTerminal.IsKeyDown(vkZ));
        FEmulation.SetKeyState(vkX, TRetromulTerminal.IsKeyDown(vkX));
        FEmulation.SetKeyState(VK_RETURN, TRetromulTerminal.IsKeyDown(VK_RETURN));
        FEmulation.SetKeyState(VK_SPACE, TRetromulTerminal.IsKeyDown(VK_SPACE));
      end;

      if TRetromulTerminal.IsKeyDown(InputPolicy.ExitKey) then
        Running := False;

      Sleep(16);
    end;
  finally
    TRetromulTerminal.Finalize;
  end;
end.
