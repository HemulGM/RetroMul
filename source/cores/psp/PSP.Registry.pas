unit PSP.Registry;

interface

uses
  System.SysUtils, System.Generics.Collections, Core.Storage, PSP.Memory,
  PSP.CPU;

type
  TPSPRegistryEntry = class
    Name: string;
    Kind: Cardinal;
    Data: TBytes;
  end;

  TPSPRegistryCategory = record
    Path: string;
    Mode: Cardinal;
  end;

  TPSPRegistry = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FStorage: IStorage;
    FDatabase: TObjectDictionary<string, TObjectList<TPSPRegistryEntry>>;
    FCategories: TDictionary<Cardinal, TPSPRegistryCategory>;
    FChanged: TDictionary<string, Boolean>;
    FOpenCount, FNextHandle: Cardinal;
    procedure AddData(const Path, Name: string; Kind: Cardinal; const Hex: string);
    function FindKey(const Path, Name: string): Integer;
    procedure Flush;
    procedure Load;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; const Storage: IStorage);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
    function ReadInteger(const Path, Name: string; Default: Cardinal): Cardinal;
  end;

implementation

uses
  System.Classes, System.IOUtils, System.JSON, System.NetEncoding, System.Math;

const
  InvalidRegistry = $80082715;
  InvalidPath = $80082716;
  MissingCategory = $80082718;
  InvalidName = $80082738;
  Denied = $8008273B;
  BadAddress = $800200D3;

constructor TPSPRegistry.Create(Memory: TPSPMemory; CPU: TPSPCPU; const Storage: IStorage);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FStorage := Storage;
  FDatabase := TObjectDictionary<string, TObjectList<TPSPRegistryEntry>>.Create([doOwnsValues]);
  FCategories := TDictionary<Cardinal, TPSPRegistryCategory>.Create;
  FChanged := TDictionary<string, Boolean>.Create;
  FNextHandle := 1;
  // Registry defaults derived from the PPSSPP firmware registry tables.
// PPSSPP Project and contributors, GPL-2.0-or-later. Port: GPL-3.0-or-later.
// Host identity, owner name and clock defaults use RetroMul virtual values.
  AddData('', 'REGISTRY', 1, '');
  AddData('REGISTRY', 'category_version', 2, '01000000');
  AddData('', 'CONFIG', 1, '');
  AddData('CONFIG', 'VIDEO', 1, '');
  AddData('CONFIG/VIDEO', 'menu_language', 4, '656e');
  AddData('CONFIG/VIDEO', 'sound_language', 4, '3030');
  AddData('CONFIG/VIDEO', 'subtitle_language', 4, '656e');
  AddData('CONFIG/VIDEO', 'appended_volume', 2, '00000000');
  AddData('CONFIG/VIDEO', 'lr_button_enable', 2, '01000000');
  AddData('CONFIG/VIDEO', 'list_play_mode', 2, '01000000');
  AddData('CONFIG/VIDEO', 'title_display_mode', 2, '00000000');
  AddData('CONFIG/VIDEO', 'output_ext_menu', 2, '00000000');
  AddData('CONFIG/VIDEO', 'output_ext_func', 2, '00000000');
  AddData('CONFIG', 'PHOTO', 1, '');
  AddData('CONFIG/PHOTO', 'slideshow_speed', 2, '01000000');
  AddData('CONFIG', 'MUSIC', 1, '');
  AddData('CONFIG/MUSIC', 'wma_play', 2, '00000000');
  AddData('CONFIG/MUSIC', 'visualizer_mode', 2, '00000000');
  AddData('CONFIG/MUSIC', 'track_info_mode', 2, '01000000');
  AddData('CONFIG', 'BROWSER', 1, '');
  AddData('CONFIG/BROWSER', 'home_uri', 3, '00');
  AddData('CONFIG/BROWSER', 'cookie_mode', 2, '01000000');
  AddData('CONFIG/BROWSER', 'proxy_mode', 2, '02000000');
  AddData('CONFIG/BROWSER', 'proxy_address', 3, '00');
  AddData('CONFIG/BROWSER', 'proxy_port', 2, '00000000');
  AddData('CONFIG/BROWSER', 'picture', 2, '01000000');
  AddData('CONFIG/BROWSER', 'animation', 2, '01000000');
  AddData('CONFIG/BROWSER', 'javascript', 2, '01000000');
  AddData('CONFIG/BROWSER', 'cache_size', 2, '00020000');
  AddData('CONFIG/BROWSER', 'char_size', 2, '01000000');
  AddData('CONFIG/BROWSER', 'disp_mode', 2, '00000000');
  AddData('CONFIG/BROWSER', 'connect_mode', 2, '00000000');
  AddData('CONFIG/BROWSER', 'flash_activated', 2, '00000000');
  AddData('CONFIG/BROWSER', 'flash_play', 2, '00000000');
  AddData('CONFIG/BROWSER', 'proxy_protect', 2, '00000000');
  AddData('CONFIG/BROWSER', 'proxy_autoauth', 2, '00000000');
  AddData('CONFIG/BROWSER', 'proxy_user', 3, '00');
  AddData('CONFIG/BROWSER', 'proxy_password', 3, '00');
  AddData('CONFIG/BROWSER', 'webpage_quality', 2, '00000000');
  AddData('CONFIG', 'BROWSER2', 1, '');
  AddData('CONFIG/BROWSER2', 'tm_service', 2, '00000000');
  AddData('CONFIG/BROWSER2', 'tm_ec_ttl', 2, '00000000');
  AddData('CONFIG/BROWSER2', 'tm_ec_ttl_update_time', 4, '0000000000000000');
  AddData('CONFIG/BROWSER2', 'tm_service_sub_status', 2, '00000000');
  AddData('CONFIG', 'LFTV', 1, '');
  AddData('CONFIG/LFTV', 'easy_reg_done', 2, '00000000');
  AddData('CONFIG/LFTV', 'netav_domain_name', 3, '00');
  AddData('CONFIG/LFTV', 'netav_ip_address', 3, '3137322e32392e37312e3100');
  AddData('CONFIG/LFTV', 'netav_port_no_home', 2, '9d130000');
  AddData('CONFIG/LFTV', 'netav_port_no_away', 2, '9d130000');
  AddData('CONFIG/LFTV', 'netav_nonce', 3, '00');
  AddData('CONFIG/LFTV', 'base_station_version', 3, '302e30303000');
  AddData('CONFIG/LFTV', 'base_station_region', 2, '00000000');
  AddData('CONFIG/LFTV', 'tuner_type', 2, '00000000');
  AddData('CONFIG/LFTV', 'input_line', 2, '00000000');
  AddData('CONFIG/LFTV', 'tv_channel', 2, '00000000');
  AddData('CONFIG/LFTV', 'bitrate_home', 2, '00000000');
  AddData('CONFIG/LFTV', 'bitrate_away', 2, '00000000');
  AddData('CONFIG/LFTV', 'channel_setting_jp', 4, '000000000000000000000000000000000000000000000000');
  AddData('CONFIG/LFTV', 'channel_setting_us', 4, '0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/LFTV', 'channel_setting_us_catv', 4, '0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/LFTV', 'overwrite_netav_setting', 2, '01000000');
  AddData('CONFIG/LFTV', 'screen_mode', 2, '00000000');
  AddData('CONFIG/LFTV', 'remocon_setting_region', 2, '00000000');
  AddData('CONFIG/LFTV', 'remocon_setting', 4, '000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/LFTV', 'remocon_setting_revision', 3, '303030302e303000');
  AddData('CONFIG/LFTV', 'external_tuner_channel', 2, '00000000');
  AddData('CONFIG/LFTV', 'ssid', 3, '00');
  AddData('CONFIG/LFTV', 'audio_gain', 2, '00000000');
  AddData('CONFIG/LFTV', 'broadcast_standard_video1', 2, '00000000');
  AddData('CONFIG/LFTV', 'broadcast_standard_video2', 2, '00000000');
  AddData('CONFIG/LFTV', 'version', 2, '00000000');
  AddData('CONFIG/LFTV', 'tv_channel_range', 2, '00000000');
  AddData('CONFIG/LFTV', 'tuner_type_no', 2, '00000000');
  AddData('CONFIG/LFTV', 'input_line_no', 2, '00000000');
  AddData('CONFIG/LFTV', 'audio_channel', 2, '00000000');
  AddData('CONFIG/LFTV', 'shared_remocon_setting', 4, '000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG', 'RSS', 1, '');
  AddData('CONFIG/RSS', 'download_items', 2, '05000000');
  AddData('CONFIG', 'ALARM', 1, '');
  AddData('CONFIG/ALARM', 'alarm_0_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_1_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_2_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_3_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_4_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_5_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_6_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_7_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_8_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_9_time', 2, 'ffffffff');
  AddData('CONFIG/ALARM', 'alarm_0_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_1_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_2_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_3_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_4_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_5_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_6_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_7_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_8_property', 2, '00000000');
  AddData('CONFIG/ALARM', 'alarm_9_property', 2, '00000000');
  AddData('CONFIG', 'PREMO', 1, '');
  AddData('CONFIG/PREMO', 'guide_page', 2, '01000000');
  AddData('CONFIG/PREMO', 'response', 2, '00000000');
  AddData('CONFIG/PREMO', 'ps3_name', 3, '00');
  AddData('CONFIG/PREMO', 'ps3_mac', 4, '000000000000');
  AddData('CONFIG/PREMO', 'ps3_keytype', 2, '00000000');
  AddData('CONFIG/PREMO', 'ps3_key', 4, '00000000000000000000000000000000');
  AddData('CONFIG/PREMO', 'custom_video_bitrate1', 2, '00000000');
  AddData('CONFIG/PREMO', 'custom_video_bitrate2', 2, '00000000');
  AddData('CONFIG/PREMO', 'custom_video_buffer1', 2, '00000000');
  AddData('CONFIG/PREMO', 'custom_video_buffer2', 2, '00000000');
  AddData('CONFIG/PREMO', 'setting_internet', 2, '00000000');
  AddData('CONFIG/PREMO', 'button_assign', 2, '00000000');
  AddData('CONFIG/PREMO', 'flags', 2, '00000000');
  AddData('CONFIG/PREMO', 'account_id', 4, '00000000000000000000000000000000');
  AddData('CONFIG/PREMO', 'login_id', 3, '00');
  AddData('CONFIG/PREMO', 'password', 3, '00');
  AddData('CONFIG', 'CAMERA', 1, '');
  AddData('CONFIG/CAMERA', 'still_size', 2, '01000000');
  AddData('CONFIG/CAMERA', 'movie_size', 2, '01000000');
  AddData('CONFIG/CAMERA', 'still_quality', 2, '00000000');
  AddData('CONFIG/CAMERA', 'movie_quality', 2, '00000000');
  AddData('CONFIG/CAMERA', 'movie_fps', 2, '01000000');
  AddData('CONFIG/CAMERA', 'white_balance', 2, '00000000');
  AddData('CONFIG/CAMERA', 'exposure_bias', 2, '00000000');
  AddData('CONFIG/CAMERA', 'shutter_sound_mode', 2, '00000000');
  AddData('CONFIG/CAMERA', 'file_folder', 2, '65000000');
  AddData('CONFIG/CAMERA', 'file_number', 2, '01000000');
  AddData('CONFIG/CAMERA', 'msid', 4, '00000000000000000000000000000000');
  AddData('CONFIG/CAMERA', 'still_effect', 2, '00000000');
  AddData('CONFIG/CAMERA', 'medium_type', 2, '00000000');
  AddData('CONFIG/CAMERA', 'file_number_eflash', 2, '01000000');
  AddData('CONFIG/CAMERA', 'folder_number_eflash', 2, '65000000');
  AddData('CONFIG', 'DISPLAY', 1, '');
  AddData('CONFIG/DISPLAY', 'aspect_ratio', 2, '00000000');
  AddData('CONFIG/DISPLAY', 'scan_mode', 2, '00000000');
  AddData('CONFIG/DISPLAY', 'screensaver_start_time', 2, '58020000');
  AddData('CONFIG/DISPLAY', 'color_space_mode', 2, '00000000');
  AddData('CONFIG/DISPLAY', 'pi_blending_mode', 2, '01000000');
  AddData('CONFIG', 'NP', 1, '');
  AddData('CONFIG/NP', 'env', 3, '6e7000');
  AddData('CONFIG/NP', 'account_id', 4, '00000000000000000000000000000000');
  AddData('CONFIG/NP', 'login_id', 3, '00');
  AddData('CONFIG/NP', 'password', 3, '00');
  AddData('CONFIG/NP', 'auto_sign_in_enable', 2, '00000000');
  AddData('CONFIG/NP', 'nav_only', 2, '00000000');
  AddData('CONFIG/NP', 'np_ad_clock_diff', 2, '00000000');
  AddData('CONFIG/NP', 'view_mode', 2, '00000000');
  AddData('CONFIG/NP', 'np_geo_filtering', 2, '00000000');
  AddData('CONFIG/NP', 'guest_country', 3, '00');
  AddData('CONFIG/NP', 'guest_lang', 3, '00');
  AddData('CONFIG/NP', 'guest_yob', 2, '00000000');
  AddData('CONFIG/NP', 'guest_mob', 2, '00000000');
  AddData('CONFIG/NP', 'guest_dob', 2, '00000000');
  AddData('CONFIG/NP', 'check_drm', 2, '00000000');
  AddData('CONFIG', 'ONESEG', 1, '');
  AddData('CONFIG/ONESEG', 'schedule_data_key', 4, '00000000000000000000000000000000');
  AddData('CONFIG', 'SYSTEM', 1, '');
  AddData('CONFIG/SYSTEM', 'owner_name', 3, '526574726f4d756c00');
  AddData('CONFIG/SYSTEM', 'backlight_brightness', 2, '03000000');
  AddData('CONFIG/SYSTEM', 'umd_autoboot', 2, '01000000');
  AddData('CONFIG/SYSTEM', 'usb_charge', 2, '01000000');
  AddData('CONFIG/SYSTEM', 'umd_cache', 2, '01000000');
  AddData('CONFIG/SYSTEM', 'usb_auto_connect', 2, '01000000');
  AddData('CONFIG/SYSTEM', 'slide_action', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'first_boot_tick', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/SYSTEM', 'owner_mob', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'owner_dob', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'slide_welcome', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'exh_mode', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'XMB', 1, '');
  AddData('CONFIG/SYSTEM/XMB', 'theme_type', 2, '00000000');
  AddData('CONFIG/SYSTEM/XMB', 'language', 2, '01000000');
  AddData('CONFIG/SYSTEM/XMB', 'button_assign', 2, '01000000');
  AddData('CONFIG/SYSTEM/XMB', 'THEME', 1, '');
  AddData('CONFIG/SYSTEM/XMB/THEME', 'color_mode', 2, '00000000');
  AddData('CONFIG/SYSTEM/XMB/THEME', 'wallpaper_mode', 2, '00000000');
  AddData('CONFIG/SYSTEM/XMB/THEME', 'system_color', 2, '00000000');
  AddData('CONFIG/SYSTEM/XMB/THEME', 'custom_theme_mode', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'SOUND', 1, '');
  AddData('CONFIG/SYSTEM/SOUND', 'main_volume', 2, '1b000000');
  AddData('CONFIG/SYSTEM/SOUND', 'mute', 2, '00000000');
  AddData('CONFIG/SYSTEM/SOUND', 'avls', 2, '00000000');
  AddData('CONFIG/SYSTEM/SOUND', 'equalizer_mode', 2, '00000000');
  AddData('CONFIG/SYSTEM/SOUND', 'operation_sound_mode', 2, '01000000');
  AddData('CONFIG/SYSTEM/SOUND', 'dynamic_normalizer', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'POWER_SAVING', 1, '');
  AddData('CONFIG/SYSTEM/POWER_SAVING', 'suspend_interval', 2, '58020000');
  AddData('CONFIG/SYSTEM/POWER_SAVING', 'backlight_off_interval', 2, '2c010000');
  AddData('CONFIG/SYSTEM/POWER_SAVING', 'wlan_mode', 2, '00000000');
  AddData('CONFIG/SYSTEM/POWER_SAVING', 'active_backlight_mode', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'LOCK', 1, '');
  AddData('CONFIG/SYSTEM/LOCK', 'password', 4, '30303030');
  AddData('CONFIG/SYSTEM/LOCK', 'parental_level', 2, '00000000');
  AddData('CONFIG/SYSTEM/LOCK', 'browser_start', 2, '00000000');
  AddData('CONFIG/SYSTEM', 'CHARACTER_SET', 1, '');
  AddData('CONFIG/SYSTEM/CHARACTER_SET', 'oem', 2, '05000000');
  AddData('CONFIG/SYSTEM/CHARACTER_SET', 'ansi', 2, '13000000');
  AddData('CONFIG', 'DATE', 1, '');
  AddData('CONFIG/DATE', 'time_format', 2, '00000000');
  AddData('CONFIG/DATE', 'date_format', 2, '02000000');
  AddData('CONFIG/DATE', 'summer_time', 2, '00000000');
  AddData('CONFIG/DATE', 'time_zone_offset', 2, '00000000');
  AddData('CONFIG/DATE', 'time_zone_area', 3, '55544300');
  AddData('CONFIG', 'NETWORK', 1, '');
  AddData('CONFIG/NETWORK', 'ADHOC', 1, '');
  AddData('CONFIG/NETWORK/ADHOC', 'channel', 2, '00000000');
  AddData('CONFIG/NETWORK/ADHOC', 'ssid_prefix', 3, '50535000');
  AddData('CONFIG/NETWORK', 'INFRASTRUCTURE', 1, '');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE', 'latest_id', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE', 'eap_md5', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE', 'auto_setting', 2, '02000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE', 'wifisvc_setting', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE', 'btdun_warnings_check', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE', '0', 1, '');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'SUB1', 1, '');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0/SUB1', 'wifisvc_auth_name', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0/SUB1', 'wifisvc_auth_key', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0/SUB1', 'wifisvc_option', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0/SUB1', 'last_leased_dhcp_addr', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0/SUB1', 'bt_id', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0/SUB1', 'at_command', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0/SUB1', 'phone_number', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'version', 2, '05000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'device', 2, '01000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'cnf_name', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'ssid', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'auth_proto', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'wep_key', 4, '0000000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'how_to_set_ip', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'ip_address', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'netmask', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'default_route', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'dns_flag', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'primary_dns', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'secondary_dns', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'auth_name', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'auth_key', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'http_proxy_flag', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'http_proxy_server', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'http_proxy_port', 2, '901f0000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'auth_8021x_type', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'auth_8021x_auth_name', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'auth_8021x_auth_key', 3, '00');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'wpa_key_type', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'wpa_key', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'browser_flag', 2, '00000000');
  AddData('CONFIG/NETWORK/INFRASTRUCTURE/0', 'wifisvc_config', 2, '00000000');
  AddData('CONFIG/NETWORK', 'GO_MESSENGER', 1, '');
  AddData('CONFIG/NETWORK/GO_MESSENGER', 'auth_name', 3, '00');
  AddData('CONFIG/NETWORK/GO_MESSENGER', 'auth_key', 3, '00');
  AddData('CONFIG', 'OSK', 1, '');
  AddData('CONFIG/OSK', 'version_id', 2, '26020000');
  AddData('CONFIG/OSK', 'disp_locale', 2, '01000000');
  AddData('CONFIG/OSK', 'writing_locale', 2, '01000000');
  AddData('CONFIG/OSK', 'input_char_mask', 2, '0f000000');
  AddData('CONFIG/OSK', 'keytop_index', 2, '05000000');
  AddData('CONFIG', 'INFOBOARD', 1, '');
  AddData('CONFIG/INFOBOARD', 'locale_lang', 3, '00');
  AddData('CONFIG/INFOBOARD', 'qa_server', 2, '00000000');
  AddData('CONFIG', 'BT', 1, '');
  AddData('CONFIG/BT', 'connect_mode', 2, '00000000');
  AddData('CONFIG/BT', 'DEVICE0', 1, '');
  AddData('CONFIG/BT/DEVICE0', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE0', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE0', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/BT', 'DEVICE1', 1, '');
  AddData('CONFIG/BT/DEVICE1', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE1', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE1', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/BT', 'DEVICE2', 1, '');
  AddData('CONFIG/BT/DEVICE2', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE2', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE2', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/BT', 'DEVICE3', 1, '');
  AddData('CONFIG/BT/DEVICE3', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE3', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE3', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/BT', 'DEVICE4', 1, '');
  AddData('CONFIG/BT/DEVICE4', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE4', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE4', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/BT', 'DEVICE5', 1, '');
  AddData('CONFIG/BT/DEVICE5', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE5', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE5', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/BT', 'DEVICE6', 1, '');
  AddData('CONFIG/BT/DEVICE6', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE6', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE6', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG/BT', 'DEVICE7', 1, '');
  AddData('CONFIG/BT/DEVICE7', 'audio_type', 2, '01000000');
  AddData('CONFIG/BT/DEVICE7', 'device_type', 2, '00000000');
  AddData('CONFIG/BT/DEVICE7', 'device_name', 4, '00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
  AddData('CONFIG', 'GAME', 1, '');
  AddData('CONFIG/GAME', 'hibernation_ow_guide', 2, '01000000');
  AddData('CONFIG/GAME', 'hibernation_op_guide', 2, '01000000');
  AddData('CONFIG/GAME', 'subs_expiration_guide', 2, '01000000');
  AddData('', 'DATA', 1, '');
  AddData('DATA', 'FONT', 1, '');
  AddData('DATA/FONT', 'path_name', 3, '666c617368303a2f666f6e7400');
  AddData('DATA/FONT', 'num_fonts', 2, '12000000');
  AddData('DATA/FONT', 'PROPERTY', 1, '');
  AddData('DATA/FONT/PROPERTY', 'INFO0', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO0', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'style', 2, '67000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'language_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'font_name', 3, '4654542d4e6577526f64696e2050726f20444200');
  AddData('DATA/FONT/PROPERTY/INFO0', 'file_name', 3, '6a706e302e70676600');
  AddData('DATA/FONT/PROPERTY/INFO0', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO0', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO1', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO1', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'style', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO1', 'file_name', 3, '6c746e302e70676600');
  AddData('DATA/FONT/PROPERTY/INFO1', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO1', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO2', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO2', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'style', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO2', 'file_name', 3, '6c746e312e70676600');
  AddData('DATA/FONT/PROPERTY/INFO2', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO2', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO3', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO3', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'style', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO3', 'file_name', 3, '6c746e322e70676600');
  AddData('DATA/FONT/PROPERTY/INFO3', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO3', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO4', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO4', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'style', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO4', 'file_name', 3, '6c746e332e70676600');
  AddData('DATA/FONT/PROPERTY/INFO4', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO4', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO5', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO5', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'style', 2, '05000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO5', 'file_name', 3, '6c746e342e70676600');
  AddData('DATA/FONT/PROPERTY/INFO5', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO5', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO6', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO6', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'style', 2, '05000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO6', 'file_name', 3, '6c746e352e70676600');
  AddData('DATA/FONT/PROPERTY/INFO6', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO6', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO7', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO7', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'style', 2, '06000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO7', 'file_name', 3, '6c746e362e70676600');
  AddData('DATA/FONT/PROPERTY/INFO7', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO7', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO8', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO8', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'style', 2, '06000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO8', 'file_name', 3, '6c746e372e70676600');
  AddData('DATA/FONT/PROPERTY/INFO8', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO8', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO9', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO9', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'style', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO9', 'file_name', 3, '6c746e382e70676600');
  AddData('DATA/FONT/PROPERTY/INFO9', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO9', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO10', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO10', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'style', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO10', 'file_name', 3, '6c746e392e70676600');
  AddData('DATA/FONT/PROPERTY/INFO10', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO10', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO11', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO11', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'style', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO11', 'file_name', 3, '6c746e31302e70676600');
  AddData('DATA/FONT/PROPERTY/INFO11', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO11', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO12', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO12', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'style', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO12', 'file_name', 3, '6c746e31312e70676600');
  AddData('DATA/FONT/PROPERTY/INFO12', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO12', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO13', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO13', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'style', 2, '05000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO13', 'file_name', 3, '6c746e31322e70676600');
  AddData('DATA/FONT/PROPERTY/INFO13', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO13', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO14', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO14', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'style', 2, '05000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO14', 'file_name', 3, '6c746e31332e70676600');
  AddData('DATA/FONT/PROPERTY/INFO14', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO14', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO15', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO15', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'style', 2, '06000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'font_name', 3, '4654542d4e6577526f64696e2050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO15', 'file_name', 3, '6c746e31342e70676600');
  AddData('DATA/FONT/PROPERTY/INFO15', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO15', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO16', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO16', 'h_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'v_size', 2, 'c0010000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'family_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'style', 2, '06000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'language_code', 2, '02000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'country_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'font_name', 3, '4654542d4d6174697373652050726f204c6174696e00');
  AddData('DATA/FONT/PROPERTY/INFO16', 'file_name', 3, '6c746e31352e70676600');
  AddData('DATA/FONT/PROPERTY/INFO16', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO16', 'shadow_option', 2, '00000000');
  AddData('DATA/FONT/PROPERTY', 'INFO17', 1, '');
  AddData('DATA/FONT/PROPERTY/INFO17', 'h_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'v_size', 2, '88020000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'h_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'v_resolution', 2, '00200000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'extra_attributes', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'weight', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'family_code', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'style', 2, '01000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'sub_style', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'language_code', 2, '03000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'region_code', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'country_code', 2, '03000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'font_name', 3, '417369614e4848283531324a6f6861622900');
  AddData('DATA/FONT/PROPERTY/INFO17', 'file_name', 3, '6b72302e70676600');
  AddData('DATA/FONT/PROPERTY/INFO17', 'expire_date', 2, '00000000');
  AddData('DATA/FONT/PROPERTY/INFO17', 'shadow_option', 2, '00000000');
  AddData('DATA', 'COUNT', 1, '');
  AddData('DATA/COUNT', 'boot_count', 2, '00000000');
  AddData('DATA/COUNT', 'game_exec_count', 2, '46000000');
  AddData('DATA/COUNT', 'slide_count', 2, '00000000');
  AddData('DATA/COUNT', 'usb_connect_count', 2, 'ec000000');
  AddData('DATA/COUNT', 'wifi_connect_count', 2, '00000000');
  AddData('DATA/COUNT', 'psn_access_count', 2, '00000000');
  AddData('', 'SYSPROFILE', 1, '');
  AddData('SYSPROFILE', 'sound_reduction', 2, '00000000');
  AddData('SYSPROFILE', 'RESOLUTION', 1, '');
  AddData('SYSPROFILE/RESOLUTION', 'horizontal', 2, '12200000');
  AddData('SYSPROFILE/RESOLUTION', 'vertical', 2, '12200000');
  Load;
end;

destructor TPSPRegistry.Destroy;
begin
  FChanged.Free;
  FCategories.Free;
  FDatabase.Free;
  inherited
end;

function TPSPRegistry.FindKey(const Path, Name: string): Integer;
begin
  Result := -1;
  var Entries: TObjectList<TPSPRegistryEntry>;
  if not FDatabase.TryGetValue(Path, Entries) then
    Exit;
  for var I := 0 to Entries.Count - 1 do
    if Entries[I].Name = Name then
      Exit(I);
end;

procedure TPSPRegistry.AddData(const Path, Name: string; Kind: Cardinal; const Hex: string);
begin
  var Entries: TObjectList<TPSPRegistryEntry>;
  if not FDatabase.TryGetValue(Path, Entries) then
  begin
    Entries := TObjectList<TPSPRegistryEntry>.Create(True);
    FDatabase.Add(Path, Entries)
  end;
  var Index := FindKey(Path, Name);
  var Entry: TPSPRegistryEntry;
  if Index < 0 then
  begin
    Entry := TPSPRegistryEntry.Create;
    Entry.Name := Name;
    Entries.Add(Entry)
  end
  else
    Entry := Entries[Index];
  Entry.Kind := Kind;
  SetLength(Entry.Data, Length(Hex) div 2);
  for var I := 0 to High(Entry.Data) do
    Entry.Data[I] := StrToInt('$' + Copy(Hex, I * 2 + 1, 2));
  var ChildPath := Name;
  if Path <> '' then
    ChildPath := Path + '/' + Name;
  if (Kind = 1) and not FDatabase.ContainsKey(ChildPath) then
    FDatabase.Add(ChildPath, TObjectList<TPSPRegistryEntry>.Create(True));
end;

function TPSPRegistry.ReadInteger(const Path, Name: string; Default: Cardinal): Cardinal;
begin
  Result := Default;
  var Index := FindKey(Path, Name);
  if Index < 0 then
    Exit;
  var Entry := FDatabase[Path][Index];
  if (Entry.Kind <> 2) or (Length(Entry.Data) <> 4) then
    Exit;
  Move(Entry.Data[0], Result, 4);
end;

procedure TPSPRegistry.Load;
begin
  if FStorage = nil then
    Exit;
  var FileName := TPath.Combine(FStorage.SaveRoot, 'psp-registry.json');
  if not FStorage.Exists(FileName) then
    Exit;
  var Data := FStorage.ReadBytes(FileName);
  if Length(Data) > 4 * 1024 * 1024 then
    raise Exception.Create('PSP registry storage exceeds limit');
  var Root := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data));
  try
    if not (Root is TJSONArray) then
      raise Exception.Create('Invalid PSP registry storage');
    if TJSONArray(Root).Count > 4096 then
      raise Exception.Create('PSP registry entry limit');
    for var Item in TJSONArray(Root) do
    begin
      var Row := Item as TJSONObject;
      var Path := Row.GetValue<string>('path');
      var Name := Row.GetValue<string>('name');
      var Kind := Row.GetValue<Integer>('kind');
      var Bytes := TNetEncoding.Base64.DecodeStringToBytes(Row.GetValue<string>('data'));
      if (Length(Path) > 256) or (Length(Name) > 27) or (Kind < 1) or (Kind > 4) or (Length(Bytes) > 65536) then
        raise Exception.Create('Invalid PSP registry entry');
      var Hex := '';
      for var B in Bytes do
        Hex := Hex + IntToHex(B, 2);
      AddData(Path, Name, Kind, Hex);
      FChanged.AddOrSetValue(Path + #0 + Name, True);
    end;
  finally
    Root.Free
  end;
end;

procedure TPSPRegistry.Flush;
begin
  if (FStorage = nil) or (FChanged.Count = 0) then
    Exit;
  var Root := TJSONArray.Create;
  try
    for var Changed in FChanged.Keys do
    begin
      var Split := Changed.IndexOf(#0);
      var Path := Changed.Substring(0, Split);
      var Name := Changed.Substring(Split + 1);
      var Index := FindKey(Path, Name);
      if Index < 0 then
        Continue;
      var Entry := FDatabase[Path][Index];
      var Row := TJSONObject.Create;
      Root.AddElement(Row);
      Row.AddPair('path', Path);
      Row.AddPair('name', Name);
      Row.AddPair('kind', TJSONNumber.Create(Entry.Kind));
      Row.AddPair('data', TNetEncoding.Base64.EncodeBytesToString(Entry.Data));
    end;
    FStorage.EnsureFolder(FStorage.SaveRoot);
    var Stream := TStringStream.Create(Root.ToJSON, TEncoding.UTF8);
    try
      FStorage.WriteAtomic(TPath.Combine(FStorage.SaveRoot, 'psp-registry.json'), Stream)
    finally
      Stream.Free
    end;
  finally
    Root.Free
  end;
end;

function TPSPRegistry.Handle(NID: Cardinal; out Value: Cardinal): Boolean;

  function ValidName(const Name: string): Boolean;
  begin
    Result := (Name <> '') and (Length(TEncoding.UTF8.GetBytes(Name)) <= 27) and not Name.Contains('/') and not Name.Contains('..')
  end;

begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  var E := FCPU.Registers[8];
  case NID of
    $92E41280:
      begin
        if not FMemory.IsValid(A, 272) or not FMemory.IsValid(C, 4) then
        begin
          Value := BadAddress;
          Exit
        end;
        if FMemory.ReadString(A + 4, 256) <> '/system' then
        begin
          Value := InvalidRegistry;
          Exit
        end;
        if (B <> 1) and (B <> 2) then
        begin
          Value := Denied;
          Exit
        end;
        FMemory.Write32(C, 0);
        Inc(FOpenCount);
        Exit;
      end;
    $FA8A5739, $39461B4D:
      begin
        if (A <> 0) or (FOpenCount = 0) then
        begin
          Value := InvalidRegistry;
          Exit
        end;
        Flush;
        if NID = $FA8A5739 then
        begin
          Dec(FOpenCount);
          if FOpenCount = 0 then
            FCategories.Clear
        end;
        Exit;
      end;
    $1D8A762E:
      begin
        if not FMemory.IsValid(D, 4) then
        begin
          Value := BadAddress;
          Exit
        end;
        FMemory.Write32(D, $FFFFFFFF);
        if (A <> 0) or (FOpenCount = 0) then
        begin
          Value := InvalidRegistry;
          Exit
        end;
        var Path := FMemory.ReadString(B, 256);
        while Path.StartsWith('/') do
          Delete(Path, 1, 1);
        if (Path = '') or Path.Contains('..') or Path.EndsWith('/') then
        begin
          Value := InvalidPath;
          Exit
        end;
        if not FDatabase.ContainsKey(Path) then
        begin
          Value := MissingCategory;
          Exit
        end;
        if (C <> 1) and (C <> 2) then
        begin
          Value := Denied;
          Exit
        end;
        var Category: TPSPRegistryCategory;
        Category.Path := Path;
        Category.Mode := C;
        var Id := FNextHandle;
        Inc(FNextHandle);
        FCategories.Add(Id, Category);
        FMemory.Write32(D, Id);
        Exit;
      end;
    $0CAE832B, $0D69BF40, $57641A81, $17768E14, $D4475AA8, $28A8E98A, $2C0DB9DD, $2D211135, $C5768D02, $30BE0259:
      ;
  else
    Exit(False)
  end;
  var Category: TPSPRegistryCategory;
  if not FCategories.TryGetValue(A, Category) then
  begin
    Value := MissingCategory;
    Exit
  end;
  if NID = $0CAE832B then
  begin
    FCategories.Remove(A);
    Exit
  end;
  if NID = $0D69BF40 then
  begin
    Flush;
    Exit
  end;
  var Entries := FDatabase[Category.Path];
  if NID = $2C0DB9DD then
  begin
    if not FMemory.IsValid(B, 4) then
      Value := BadAddress
    else
      FMemory.Write32(B, Entries.Count);
    Exit
  end;
  if NID = $2D211135 then
  begin
    if (C > 4096) or not FMemory.IsValid(B, C * 27) then
    begin
      Value := BadAddress;
      Exit
    end;
    for var I := 0 to Min(Integer(C), Entries.Count) - 1 do
    begin
      var At := B + Cardinal(I) * 27;
      FMemory.Zero(At, 27);
      FMemory.Load(At, Copy(TEncoding.UTF8.GetBytes(Entries[I].Name), 0, 26))
    end;
    Exit;
  end;
  var Index: Integer;
  var Name: string;
  if NID = $28A8E98A then
    Index := Integer(B)
  else
  begin
    Name := FMemory.ReadString(B, 28);
    if not ValidName(Name) then
    begin
      Value := InvalidName;
      Exit
    end;
    Index := FindKey(Category.Path, Name)
  end;
  if (NID = $57641A81) or (NID = $17768E14) then
  begin
    if Category.Mode = 2 then
    begin
      Value := Denied;
      Exit
    end;
    if (NID = $57641A81) and (Index >= 0) then
    begin
      Value := $80082728;
      Exit
    end;
    if NID = $57641A81 then
    begin
      if (C < 1) or (C > 4) or (D > 65536) or ((C = 2) and (D <> 4)) then
      begin
        Value := $FFFFFFFF;
        Exit
      end;
      AddData(Category.Path, Name, C, StringOfChar('0', D * 2));
      FChanged.AddOrSetValue(Category.Path + #0 + Name, True);
      Exit;
    end;
    if (Index < 0) or (D > 65536) or not FMemory.IsValid(C, D) then
    begin
      Value := $FFFFFFFF;
      Exit
    end;
    var Entry := Entries[Index];
    if (Entry.Kind = 1) or ((Entry.Kind = 2) and (D < 4)) then
    begin
      Value := $FFFFFFFF;
      Exit
    end;
    if Entry.Kind = 2 then
      Entry.Data := FMemory.ReadBytes(C, 4)
    else
      Entry.Data := FMemory.ReadBytes(C, D);
    if (Entry.Kind = 3) and ((Length(Entry.Data) = 0) or (Entry.Data[High(Entry.Data)] <> 0)) then
      Entry.Data := Entry.Data + TBytes.Create(0);
    FChanged.AddOrSetValue(Category.Path + #0 + Name, True);
    Exit;
  end;
  if (Index < 0) or (Index >= Entries.Count) then
  begin
    Value := $FFFFFFFF;
    Exit
  end;
  var Entry := Entries[Index];
  if (NID = $D4475AA8) or (NID = $C5768D02) then
  begin
    var TypeAddress := C;
    var SizeAddress := D;
    if NID = $D4475AA8 then
    begin
      if not FMemory.IsValid(C, 4) then
      begin
        Value := BadAddress;
        Exit
      end;
      FMemory.Write32(C, Index);
      TypeAddress := D;
      SizeAddress := E;
    end;
    if not FMemory.IsValid(TypeAddress, 4) or not FMemory.IsValid(SizeAddress, 4) then
    begin
      Value := BadAddress;
      Exit
    end;
    FMemory.Write32(TypeAddress, Entry.Kind);
    FMemory.Write32(SizeAddress, Length(Entry.Data));
    Exit;
  end;
  if (D < Cardinal(Length(Entry.Data))) or not FMemory.IsValid(C, D) then
  begin
    Value := $FFFFFFFF;
    Exit
  end;
  FMemory.Load(C, Entry.Data);
end;

end.

