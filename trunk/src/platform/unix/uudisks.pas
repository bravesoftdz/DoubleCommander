{
   Double Commander
   -------------------------------------------------------------------------
   Interface to UDisks service via DBUS.

   Copyright (C) 2010  Przemyslaw Nagay (cobines@gmail.com)

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
}

unit uUDisks;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TStringArray = array of string;
  TUDisksMethod = (UDisks_DeviceAdded,
                   UDisks_DeviceRemoved,
                   UDisks_DeviceChanged);

  TUDisksDeviceNotify = procedure(Reason: TUDisksMethod; const ObjectPath: UTF8String) of object;

const
  UDisksDevicePathPrefix  = '/org/freedesktop/UDisks/devices/';

function GetObjectProperty(const ObjectPath: UTF8String;
                           const PropertyName: UTF8String;
                           out Value: UTF8String): Boolean;
function GetObjectProperty(const ObjectPath: UTF8String;
                           const PropertyName: UTF8String;
                           out Value: Boolean): Boolean;
function GetObjectProperty(const ObjectPath: UTF8String;
                           const PropertyName: UTF8String;
                           out Value: TStringArray): Boolean;
function EnumerateDevices(out DevicesList: TStringArray): Boolean;
function Initialize: Boolean;
procedure Finalize;
procedure DispatchMessages;
procedure AddObserver(Func: TUDisksDeviceNotify);
procedure RemoveObserver(Func: TUDisksDeviceNotify);

implementation

uses
  dbus, fgl, ExtCtrls;

{$IF (FPC_VERSION <= 2) and (FPC_RELEASE <= 4) and (FPC_PATCH <= 2)}
type
  DBusHandleMessageFunction = function(connection: PDBusConnection;
   message_: PDBusMessage; user_data: Pointer): DBusHandlerResult; cdecl;

{ Filters }

function dbus_connection_add_filter(connection: PDBusConnection;
 function_: DBusHandleMessageFunction;
 user_data: Pointer; free_data_function: DBusFreeFunction): dbus_bool_t; cdecl; external LibDBus;
procedure dbus_connection_remove_filter (connection: PDBusConnection;
 function_: DBusHandleMessageFunction; user_data: Pointer); cdecl; external LibDBus;
{$ENDIF}

type
  TUDisksObserverList = specialize TFPGList<TUDisksDeviceNotify>;

  TDummy = class
    procedure OnTimer(Sender: TObject);
  end;

var
  DBusConnectionOpen: Boolean = False;
  conn: PDBusConnection;
  error: DBusError;
  Observers: TUDisksObserverList = nil;
  InitializeCounter: Integer = 0;
  ConnTimer: TTimer = nil;
  Dummy: TDummy = nil;

const
  UDisksMethodStr: array[TUDisksMethod] of string =
                     ('DeviceAdded',
                      'DeviceRemoved',
                      'DeviceChanged');

  UDisksAddress           = 'org.freedesktop.UDisks';
  UDisksObject            = '/org/freedesktop/UDisks';
  UDisksInterface         = 'org.freedesktop.UDisks';
  UDisksDeviceInterface   = 'org.freedesktop.UDisks.Device';
  DBusPropertiesInterface = 'org.freedesktop.DBus.Properties';

  UDisksFilterStr = 'type=''signal'',' +
                    'sender=''' + UDisksAddress + ''',' +
                    'path=''' + UDisksObject + ''',' +
                    'interface=''' + UDisksInterface + '''';

procedure Print(const sMessage: String);
begin
  WriteLn('UDisks: ', sMessage);
end;

function CheckError(const sMessage: String; pError: PDBusError): Boolean;
begin
  if (dbus_error_is_set(pError) <> 0) then
  begin
    Print(sMessage + ': ' + pError^.name + ' ' + pError^.message);
    dbus_error_free(pError);
    Result := True;
  end
  else
    Result := False;
end;

function GetObjectPath(message: PDBusMessage; out ObjectPath: UTF8String): Boolean;
var
  object_path: PChar;
  got_args: dbus_bool_t;
begin
  dbus_error_init(@error);
  got_args := dbus_message_get_args(message, @error,
                                    DBUS_TYPE_OBJECT_PATH, [@object_path,
                                    DBUS_TYPE_INVALID]);
  if CheckError('Cannot get object path', @error) then
    Result := False
  else if got_args = 0 then
  begin
    Print('Cannot get object path');
    Result := False;
  end
  else
  begin
    ObjectPath := StrPas(object_path);
    Result := True;
  end;
end;

function GetBasicVal(pIter: PDBusMessageIter;
                     dbus_type: Integer;
                     Ptr: Pointer): Boolean;
begin
  if dbus_message_iter_get_arg_type(pIter) <> dbus_type then
  begin
    Print('Not a valid type');
    Result := False;
  end
  else
  begin
    dbus_message_iter_get_basic(pIter, Ptr);
    Result := True;
  end;
end;

function GetArrayOfString(pIter: PDBusMessageIter;
                          dbus_string_type: Integer): TStringArray;
var
  arrayIter: DBusMessageIter;
  counter: Integer;
  StringPtr: PChar;
begin
  Result := nil;

  if (dbus_message_iter_get_arg_type(pIter) <> DBUS_TYPE_ARRAY) or
     (dbus_message_iter_get_element_type(pIter) <> dbus_string_type) then
  begin
    Print('Not a valid type');
  end
  else
  begin
    dbus_message_iter_recurse(pIter, @arrayIter);

    // Check if array is not empty (if the first element is there).
    if dbus_message_iter_get_arg_type(@arrayIter) <> DBUS_TYPE_INVALID then
    begin
      counter := 0;
      repeat
        if GetBasicVal(@arrayIter, dbus_string_type, @StringPtr) and
           Assigned(StringPtr) then
        begin
          SetLength(Result, counter + 1);
          Result[counter] := StrPas(StringPtr);
          Inc(counter);
        end;
      until (dbus_message_iter_next(@arrayIter) = 0);
    end;
  end;
end;

function GetArrayOfString(pIter: PDBusMessageIter): TStringArray;
begin
  Result := GetArrayOfString(pIter, DBUS_TYPE_STRING);
end;

function GetArrayOfObjectPath(pIter: PDBusMessageIter): TStringArray;
begin
  // Object path is an utf-8 string in DBUS, but marked with a different type
  // than normal DBUS_TYPE_STRING.
  Result := GetArrayOfString(pIter, DBUS_TYPE_OBJECT_PATH);
end;

// reply needs to be freed by the caller.
function SendWithReply(message: PDBusMessage;
                       out reply: PDBusMessage;
                       expectedReplyType: Integer;
                       replyIter: PDBusMessageIter): Boolean;
begin
  dbus_error_init (@error);
  reply := dbus_connection_send_with_reply_and_block(conn, message, -1, @error);

  if CheckError('Error sending message', @error) then
    Result := False
  else if not Assigned(reply) then
  begin
    Print('Reply not received');
    Result := False;
  end
  else if dbus_message_iter_init(reply, replyIter) = 0 then
  begin
    Print('Reply has no arguments');
    Result := False;
  end
  else if dbus_message_iter_get_arg_type(replyIter) <> expectedReplyType then
  begin
    Print('Invalid argument type in reply.');
    Result := False;
  end
  else
    Result := True;

  if (not Result) and Assigned(reply) then
    dbus_message_unref(reply);
end;

function Invoke_GetProperty(const ObjectPath: UTF8String;
                            const PropertyName: UTF8String;
                            out reply: PDBusMessage; // reply needs to be freed by the caller.
                            pVariantIter: PDBusMessageIter): Boolean;
var
  deviceInterfaceNamePChar: PChar;
  propertyNamePChar: PChar;
  message: PDBusMessage;
  replyIter: DBusMessageIter;
begin
  message := dbus_message_new_method_call(UDisksAddress,
                                          PChar(ObjectPath),
                                          DBusPropertiesInterface,
                                          'Get');
  if not Assigned(message) then
  begin
    Print('Cannot create message "Get"');
    Exit(False);
  end;

  deviceInterfaceNamePChar := PChar(UDisksDeviceInterface);
  propertyNamePChar := PChar(PropertyName);
  if dbus_message_append_args(message,
                              DBUS_TYPE_STRING, [@deviceInterfaceNamePChar,
                              DBUS_TYPE_STRING, @propertyNamePChar,
                              DBUS_TYPE_INVALID]) = 0 then
  begin
    Print('Cannot append arguments');
    Result := False;
  end
  else if SendWithReply(message, reply, DBUS_TYPE_VARIANT, @replyIter) then
  begin
    dbus_message_iter_recurse(@replyIter, pVariantIter);
    Result := True;
  end
  else
    Result := False;

  dbus_message_unref(message);
end;

function Invoke_EnumerateDevices(out reply: PDBusMessage; // reply needs to be freed by the caller.
                                 pReplyIter: PDBusMessageIter): Boolean;
var
  message: PDBusMessage;
begin
  message := dbus_message_new_method_call(UDisksAddress,
                                          UDisksObject,
                                          UDisksInterface,
                                          'EnumerateDevices');
  if not Assigned(message) then
  begin
    Print('Cannot create message "EnumerateDevices"');
    Result := False;
  end
  else
  begin
    Result := SendWithReply(message, reply, DBUS_TYPE_ARRAY, pReplyIter);
    dbus_message_unref(message);
  end;
end;

function GetObjectProperty(const ObjectPath: UTF8String;
                           const PropertyName: UTF8String;
                           out Value: UTF8String): Boolean;
var
  reply: PDBusMessage;
  itVariant: DBusMessageIter;
  StringPtr: PChar;
begin
  Result := Invoke_GetProperty(ObjectPath, PropertyName, reply, @itVariant);
  if Result then
  begin
    Result := GetBasicVal(@itVariant, DBUS_TYPE_STRING, @StringPtr);
    if Result and Assigned(StringPtr) then
      Value := StrPas(StringPtr);
    dbus_message_unref(reply);
  end;
end;

function GetObjectProperty(const ObjectPath: UTF8String;
                           const PropertyName: UTF8String;
                           out Value: Boolean): Boolean;
var
  reply: PDBusMessage;
  itVariant: DBusMessageIter;
  DbusValue: dbus_bool_t;
begin
  Result := Invoke_GetProperty(ObjectPath, PropertyName, reply, @itVariant);
  if Result then
  begin
    Result := GetBasicVal(@itVariant, DBUS_TYPE_BOOLEAN, @DbusValue);
    if Result then
      Value := DbusValue <> 0;
    dbus_message_unref(reply);
  end;
end;

function GetObjectProperty(const ObjectPath: UTF8String;
                           const PropertyName: UTF8String;
                           out Value: TStringArray): Boolean;
var
  reply: PDBusMessage;
  itVariant: DBusMessageIter;
begin
  Result := Invoke_GetProperty(ObjectPath, PropertyName, reply, @itVariant);
  if Result then
  begin
    Value := GetArrayOfString(@itVariant);
    Result := Assigned(Value);
    dbus_message_unref(reply);
  end;
end;

function EnumerateDevices(out DevicesList: TStringArray): Boolean;
var
  reply: PDBusMessage;
  replyIter: DBusMessageIter;
begin
  Result := Invoke_EnumerateDevices(reply, @replyIter);
  if Result then
  begin
    DevicesList := GetArrayOfObjectPath(@replyIter);
    dbus_message_unref(reply);
    Result := Assigned(DevicesList);
  end;
end;

function FilterFunc(connection: PDBusConnection;
                    message: PDBusMessage;
                    user_data: Pointer): DBusHandlerResult; cdecl;
var
  DeviceObjectPath: UTF8String;
  i: Integer;
begin
  if dbus_message_is_signal(message, 'org.freedesktop.DBus.Local', 'Disconnected') <> 0 then
  begin
    // The bus is disconnecting. "Disconnected" is the last signal in connection.
    Print('Disconnected from DBUS');
    DBusConnectionOpen := False;
    Exit(DBUS_HANDLER_RESULT_HANDLED);
  end
  // DeviceAdded
  else if dbus_message_is_signal(message, UDisksInterface,
                                 PChar(UDisksMethodStr[UDisks_DeviceAdded])) <> 0 then
  begin
    if GetObjectPath(message, DeviceObjectPath) then
    begin
      Print('Device added: ' + DeviceObjectPath);
      for i := 0 to Observers.Count - 1 do
        Observers[i](UDisks_DeviceAdded, DeviceObjectPath);
    end;
    Exit(DBUS_HANDLER_RESULT_HANDLED);
  end
  // DeviceRemoved
  else if dbus_message_is_signal(message, UDisksInterface,
                                 PChar(UDisksMethodStr[UDisks_DeviceRemoved])) <> 0 then
  begin
    if GetObjectPath(message, DeviceObjectPath) then
    begin
      Print('Device removed: ' + DeviceObjectPath);
      for i := 0 to Observers.Count - 1 do
        Observers[i](UDisks_DeviceRemoved, DeviceObjectPath);
    end;
    Exit(DBUS_HANDLER_RESULT_HANDLED);
  end
  // DeviceChanged
  else if dbus_message_is_signal(message, UDisksInterface,
                                 PChar(UDisksMethodStr[UDisks_DeviceChanged])) <> 0 then
  begin
    if GetObjectPath(message, DeviceObjectPath) then
    begin
      Print('Device changed: ' + DeviceObjectPath);
      for i := 0 to Observers.Count - 1 do
        Observers[i](UDisks_DeviceChanged, DeviceObjectPath);
    end;
    Exit(DBUS_HANDLER_RESULT_HANDLED);
  end;
  Exit(DBUS_HANDLER_RESULT_NOT_YET_HANDLED);
end;

function CheckUDisksService: Boolean;
var
  udisks_exists: dbus_bool_t;
  start_reply: dbus_uint32_t;
  daemon_version: UTF8String;
begin
  dbus_error_init(@error);
  udisks_exists := dbus_bus_name_has_owner(conn, UDisksAddress, @error);
  if CheckError('Cannot query UDisks on DBUS', @error) then
    Exit(False);

  if udisks_exists = 0 then
  begin
    dbus_error_init(@error);
    dbus_bus_start_service_by_name(conn, UDisksAddress, 0, @start_reply, @error);

    if CheckError('Cannot request service to start', @error) then
      Exit(False);

    case start_reply of
      DBUS_START_REPLY_SUCCESS:
        Print('Service successfully started.');
      DBUS_START_REPLY_ALREADY_RUNNING:
        Print('Service already running.');
    end;
  end
  else
    Print('Service found running.');

  if GetObjectProperty(UDisksObject, 'DaemonVersion', daemon_version) then
    Print('Version ' + daemon_version);

  Result := True;
end;

function Initialize: Boolean;
var
  i: TUDisksMethod;
begin
  Result := False;
  Inc(InitializeCounter);
  try
    if InitializeCounter > 1 then
    begin
      // Already initialized.
      Result := True;
      Exit;
    end;

    dbus_error_init(@error);
    conn := dbus_bus_get(DBUS_BUS_SYSTEM, @error);
    if CheckError('Cannot acquire connection to DBUS system bus', @error) then
      Exit;

    if Assigned(conn) then
      DBusConnectionOpen := True
    else
      Exit;

    // Disable exiting the application when it is disconnected from DBUS.
    dbus_connection_set_exit_on_disconnect(conn, 0);

    // Check if UDisks is running.
    if not CheckUDisksService then
      Exit;

    Observers := TUDisksObserverList.Create;

    dbus_error_init(@error);
    for i := Low(UDisksMethodStr) to High(UDisksMethodStr) do
    begin
      dbus_bus_add_match(
        conn,
        PChar(UDisksFilterStr + ',member=''' + UDisksMethodStr[i] + ''''),
        @error);

      CheckError('Cannot add matching rule', @error);
    end;

    Result := dbus_connection_add_filter(conn, @FilterFunc, nil, nil) <> 0;

    if not Result then
      Print('Cannot add filter for DBUS connection')
    else
    begin
      Dummy := TDummy.Create;
      ConnTimer := TTimer.Create(nil);
      ConnTimer.Interval := 500;
      ConnTimer.OnTimer := @Dummy.OnTimer;
      ConnTimer.Enabled := True;
    end;

  finally
    if not Result then
      Finalize;
  end;
end;

procedure Finalize;
var
  i: TUDisksMethod;
begin
  Dec(InitializeCounter);
  if InitializeCounter <> 0 then
    // Don't finalize yet.
    Exit;

  if Assigned(ConnTimer) then
    FreeAndNil(ConnTimer);

  if DBusConnectionOpen then
  begin
    dbus_error_init(@error);

    for i := Low(UDisksMethodStr) to High(UDisksMethodStr) do
    begin
      dbus_bus_remove_match(
        conn,
        PChar(UDisksFilterStr + ',member=''' + UDisksMethodStr[i] + ''''),
        @error);

      CheckError('Cannot remove matching rule', @error);
    end;

    dbus_connection_remove_filter(conn, @FilterFunc, nil);
    dbus_connection_unref(conn);
    DBusConnectionOpen := False;
  end;

  if Assigned(Observers) then
    FreeAndNil(Observers);

  if Assigned(Dummy) then
    FreeAndNil(Dummy);
end;

procedure DispatchMessages;
begin
  if dbus_connection_read_write_dispatch(conn, 1) = 0 then
    DBusConnectionOpen := False;
end;

procedure AddObserver(Func: TUDisksDeviceNotify);
begin
  if Observers.IndexOf(Func) < 0 then
    Observers.Add(Func);
end;

procedure RemoveObserver(Func: TUDisksDeviceNotify);
begin
  Observers.Remove(Func);
end;

procedure TDummy.OnTimer(Sender: TObject);
begin
  DispatchMessages;
end;

end.
