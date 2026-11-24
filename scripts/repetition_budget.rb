# frozen_string_literal: true

# 容量は出力先内の通常ファイルの論理バイト数で数える。
class RepetitionBudget
  def initialize(root, max_bytes)
    @root = File.realpath(root)
    @max_bytes = max_bytes
    @sealed = {}
  end

  # 集計などの書き込み前には、これから増えるバイト数も含めて判定する。
  def check!(additional_bytes = 0)
    return unless @max_bytes

    needed = tree_bytes(@root) + additional_bytes
    raise "保存容量の上限を超えます (#{needed} > #{@max_bytes} bytes)" if needed > @max_bytes
  end

  # 以降変更しない反復のサイズを固定し、大きな過去履歴の再走査を避ける。
  def seal!(directory)
    return unless @max_bytes

    path = File.realpath(directory)
    raise '反復ディレクトリが実行先の外にあります' unless path.start_with?(@root + File::SEPARATOR)

    @sealed[path] = tree_bytes(path)
  end

  def run!(*command)
    check!
    # 親だけが中断された場合にも、同じグループの DuckDB まで停止する。
    pid = Process.spawn(*command, pgroup: true)
    waiter = Process.detach(pid)
    until waiter.join(@max_bytes ? 0.25 : nil)
      check!
    end
    status = waiter.value
    raise "#{command.first} #{command[1]} が失敗しました (#{status})" unless status.success?

    check!
    completed = true
  ensure
    if pid && !completed
      signal_group('TERM', pid)
      waiter ||= Process.detach(pid)
      waiter.join(1)
      signal_group('KILL', pid)
      waiter.join
    end
  end

  private

  def tree_bytes(path)
    return @sealed[path] if @sealed.key?(path)

    stat = File.lstat(path)
    return stat.size if stat.file?
    return 0 unless stat.directory?

    Dir.each_child(path).sum { |name| tree_bytes(File.join(path, name)) }
  rescue Errno::ENOENT
    # 生成器は完成時に一時ディレクトリを rename する。終了後にもう一度数える。
    0
  end

  def signal_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    # グループ全体がすでに終了している。
    nil
  end
end
