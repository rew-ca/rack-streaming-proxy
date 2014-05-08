require 'rack/streaming_proxy/errors'

class Rack::StreamingProxy::Response
  include Rack::Utils # For HeaderHash

  attr_reader :status, :headers
  attr_accessor :client_http_version

  def initialize(piper)
    @piper = piper
    @client_http_version = '1.1'
    receive
  end

  # This method is called by Rack itself, to iterate over the proxied contents.
  def each
    if @body_permitted
      term = "\r\n"

      while chunk = read_from_destination
        break if chunk == :done
        if @chunked
          size = bytesize(chunk)
          next if size == 0
          yield [size.to_s(16), term, chunk, term].join
        else
          yield chunk
        end
      end

      finish

      yield ['0', term, '', term].join

    end
  end

private

  def receive
    # The first item received from the child will either be an HTTP status code or an Exception.
    @status = read_from_destination

    if @status.nil? # This should never happen
      Rack::StreamingProxy::Proxy.log :error, "Parent received unexpected nil status!"
      finish
      raise Rack::StreamingProxy::UnknownError
    elsif @status.kind_of? Exception
      e = @status
      Rack::StreamingProxy::Proxy.log :error, "Parent received an Exception from Child: #{e.class}: #{e.message}"
      finish
      raise e
    end

    Rack::StreamingProxy::Proxy.log :debug, "Parent received: Status = #{@status}."
    @body_permitted = read_from_destination
    Rack::StreamingProxy::Proxy.log :debug, "Parent received: Reponse has body? = #{@body_permitted}."
    @headers = HeaderHash.new(read_from_destination)

    #SEMI HACK - force chunked respone - puma can only understand chunked responses, and any HTTP1.1 client (ie: any browser we support) can handle it
    chunked = (@headers['Transfer-Encoding'] == 'chunked')
    puts "Would be chunked? #{chunked}"
    @chunked = true
    #@chunked = (@headers['Transfer-Encoding'] == 'chunked')
    finish unless @body_permitted # If there is a body, finish will be called inside each.
  end

  # parent needs to wait for the child, or it results in the child process becoming defunct, resulting in zombie processes!
  # This is very important. See: http://siliconisland.ca/2013/04/26/beware-of-the-zombie-process-apocalypse/
  def finish
    Rack::StreamingProxy::Proxy.log :info, "Parent process #{Process.pid} waiting for child process #{@piper.pid} to exit."
    @piper.wait
  end

  def read_from_destination
    @piper.gets
  end

end
