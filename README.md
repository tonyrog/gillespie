# Gillespie - multi device LPC flash tool

Flash the same firmware onto up to N LPC boards at once, one
serial-ttl-uart per board (10 on a usb hub today). Built on
[elpcisp](../elpcisp) and [uart](../uart).

## Build and run

    make            # build
    make run        # start the wx gui (uses local.config if present, else sys.config)
    make shell      # erlang shell with gillespie started

From the shell:

    gillespie:list_devices().   % which uarts are present
    gillespie:flash().          % flash configured firmware to all present uarts
    gillespie:flash("fw.bin").
    gillespie:gui().            % start the gui

## Configuration

`sys.config` holds defaults, copy it to `local.config` and edit.
"Save config" in the gui writes the current settings back to the file
given with `-config` (default `local.config`).

    {uart_list, [{DevNo, DevicePattern} |
                 {DevNo, DevicePattern, [{enable,false}]}]}
    {filename, "firmware.bin"}     % .bin or .ihex
    {baud, 115200}                 % sync baud
    {flash_baud, 115200}           % baud while writing
    {oscillator, 12000}            % kHz
    {addr, 0}                      % load address for .bin
    {sync_retry, 3}
    {sync_tmo, 2000}               % ms
    {control, false}               % DTR/RTS reset control
    {control_inv, false}
    {control_swap, false}

`DevicePattern` is a wildcard, typically `/dev/serial/by-path/...` so a
uart is identified by its physical usb port, not by enumeration order.

## GUI

One page: firmware selector, options, one row per uart with
enable checkbox / device / chip / connected status / progress / result,
buttons Rescan, Flash all, Abort, Save config and a log window.
