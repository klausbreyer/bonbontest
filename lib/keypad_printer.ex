defmodule KeypadPrinter do
  use GenServer

  @enter_codes MapSet.new([28, 96])

  # numpad keys in Linux input keycodes:
  # KP0..KP9: 82,79,80,81,75,76,77,71,72,73 (depends on mapping)
  # But many USB numpads send KEY_0..KEY_9 (11..20).
  @kp_map %{
    82 => "0", 79 => "1", 80 => "2", 81 => "3", 75 => "4",
    76 => "5", 77 => "6", 71 => "7", 72 => "8", 73 => "9",
    11 => "0", 2 => "1", 3 => "2", 4 => "3", 5 => "4",
    6 => "5", 7 => "6", 8 => "7", 9 => "8", 10 => "9"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    kbd = Keyword.fetch!(opts, :kbd)       # e.g. "/dev/input/by-id/usb-...-event-kbd"
    printer = Keyword.get(opts, :printer, "/dev/usb/lp0")

    {:ok, kfd} = File.open(kbd, [:read, :binary])
    {:ok, pfd} = File.open(printer, [:write, :binary])

    state = %{kfd: kfd, pfd: pfd, buf: ""}

    # start reading
    IO.puts("[keypad_printer] ready to accept input from #{kbd}")
    send(self(), :read)
    {:ok, state}
  end

  @impl true
  def handle_info(:read, state) do
    # Linux struct input_event:
    # struct timeval { long tv_sec; long tv_usec; };
    # __u16 type; __u16 code; __s32 value;
    # On 64-bit kernel long is 8 bytes; on 32-bit it's 4.
    #
    # Raspberry Pi OS is commonly 64-bit nowadays; but can be 32-bit.
    # We'll try 24 bytes (64-bit) first, then fallback to 16 bytes (32-bit).
    case read_event(state.kfd) do
      {:ok, {type, code, value}} ->
        IO.puts("[keypad_printer] key event type=#{type} code=#{code} value=#{value}")
        state = handle_key(type, code, value, state)
        send(self(), :read)
        {:noreply, state}

      :eof ->
        Process.send_after(self(), :read, 50)
        {:noreply, state}

      {:error, _} ->
        Process.send_after(self(), :read, 200)
        {:noreply, state}
    end
  end

  defp handle_key(0x01, code, 1, state) do
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

  defp read_event(fd) do
    # try 24 bytes (64-bit timeval)
    case IO.binread(fd, 24) do
      :eof ->
        :eof

      bin when is_binary(bin) and byte_size(bin) == 24 ->
        # 8+8 + 2+2 + 4 = 24
        <<_sec::signed-little-64, _usec::signed-little-64,
          type::unsigned-little-16, code::unsigned-little-16, value::signed-little-32>> = bin
        {:ok, {type, code, value}}

      bin when is_binary(bin) and byte_size(bin) < 24 ->
        # maybe 32-bit kernel, try reading remaining to make 16
        case bin <> (IO.binread(fd, 16 - byte_size(bin)) || <<>>) do
          b when byte_size(b) == 16 ->
            <<_sec::signed-little-32, _usec::signed-little-32,
              type::unsigned-little-16, code::unsigned-little-16, value::signed-little-32>> = b
            {:ok, {type, code, value}}

          _ ->
            {:error, :short_read}
        end
    end
  end
end
