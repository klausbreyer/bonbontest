defmodule KeypadPrinter.Application do
  use Application

  @impl true
  def start(_type, _args) do
    kbd = System.get_env("KBD_DEV") || "/dev/input/by-id/usb-YOURKEYBOARD-event-kbd"
    printer = System.get_env("PRINTER_DEV") || "/dev/usb/lp0"

    children = [
      {KeypadPrinter, kbd: kbd, printer: printer}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: KeypadPrinter.Supervisor)
  end
end
