defmodule KeypadPrinter do
  @moduledoc """
  Reads key events from a Linux evdev keyboard device (/dev/input/event*),
  collects digits from a numpad, and prints the buffered number when Enter is pressed.

  Usage (dev):
    KBD_DEV="/dev/input/by-id/usb-SIGMACHIP_USB_Keyboard-event-kbd" \
    PRINTER_DEV="/dev/usb/lp0" \
    mix run --no-halt
  """

  use GenServer

  @type_key 0x01

  # Normal Enter (KEY_ENTER) and Keypad Enter (KEY_KPENTER)
  @enter_codes MapSet.new([28, 96])

  # Your device sends KP1..KP9 as:
  # 1..3 => 79..81, 4..6 => 75..77, 7..9 => 71..73
  # 0 is usually 82 (KEY_KP0) – included.
  @kp_map %{
    82 => "0",
    79 => "1",
    80 => "2",
    81 => "3",
    75 => "4",
    76 => "5",
    77 => "6",
    71 => "7",
    72 => "8",
    73 => "9"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    kbd = Keyword.fetch!(opts, :kbd)
    printer = Keyword.get(opts, :printer, "/dev/usb/lp0")

    # IMPORTANT: use :raw and :file.read for stable evdev reads
    kfd =
      case File.open(kbd, [:read, :binary, :raw]) do
        {:ok, fd} -> fd
        {:error, reason} -> raise "Cannot open keyboard device #{kbd}: #{inspect(reason)}"
      end

    pfd =
      case File.open(printer, [:write, :binary, :raw]) do
        {:ok, fd} -> fd
        {:error, reason} -> raise "Cannot open printer device #{printer}: #{inspect(reason)}"
      end

    IO.puts("[keypad_printer] ready to accept input from #{kbd}")
    IO.puts("[keypad_printer] printing to #{printer}")

    state = %{kfd: kfd, pfd: pfd, buf: ""}

    send(self(), :read)
    {:ok, state}
  end

  @impl true
  def handle_info(:read, state) do
    case read_event(state.kfd) do
      {:ok, {type, code, value}} ->
        # Debug: show every event (comment out later if noisy)
        IO.puts("[keypad_printer] event type=#{type} code=#{code} value=#{value}")

        state = handle_key(type, code, value, state)
        send(self(), :read)
        {:noreply, state}

      :eof ->
        Process.send_after(self(), :read, 50)
        {:noreply, state}

      {:error, :eintr} ->
        send(self(), :read)
        {:noreply, state}

      {:error, reason} ->
        IO.puts("[keypad_printer] read error: #{inspect(reason)}")
        Process.send_after(self(), :read, 200)
        {:noreply, state}
    end
  end

  # key press value: 1 = press, 0 = release, 2 = repeat
  defp handle_key(@type_key, code, 1, state) do
    cond do
      MapSet.member?(@enter_codes, code) ->
        IO.puts("[keypad_printer] ENTER (code=#{code}) -> printing: #{inspect(state.buf)}")
        print_line(state.pfd, state.buf)
        %{state | buf: ""}

      digit = @kp_map[code] ->
        IO.puts("[keypad_printer] digit (code=#{code}) -> \"#{digit}\"")
        %{state | buf: state.buf <> digit}

      true ->
        IO.puts("[keypad_printer] key code=#{code} ignored (not mapped)")
        state
    end
  end

  defp handle_key(_type, _code, _value, state), do: state

  defp print_line(pfd, line) do
    data = line <> "\n\n\n"
    IO.binwrite(pfd, data)
  end

  # Linux struct input_event on 64-bit userspace:
  # 8 + 8 + 2 + 2 + 4 = 24 bytes
  defp read_event(fd) do
    case :file.read(fd, 24) do
      {:ok,
       <<_sec::signed-little-64, _usec::signed-little-64, type::unsigned-little-16,
         code::unsigned-little-16, value::signed-little-32>>} ->
        {:ok, {type, code, value}}

      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}
    end
  end
end
