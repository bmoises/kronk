require 'test/test_helper'

class TestRequest < Test::Unit::TestCase

  def test_parse
    raw = "POST /foobar\r\nAccept: json\r\nHost: example.com\r\n\r\nfoo=bar"
    req = Kronk::Request.parse(raw)

    assert_equal Kronk::Request, req.class
    assert_equal URI.parse("http://example.com/foobar"), req.uri
    assert_equal "json", req.headers['Accept']
    assert_equal "foo=bar", req.body
  end


  def test_parse_url
    raw = "https://example.com/foobar?foo=bar"
    req = Kronk::Request.parse(raw)

    assert_equal Kronk::Request, req.class
    assert_equal URI.parse("https://example.com/foobar?foo=bar"), req.uri
  end


  def test_parse_url_path
    raw = "/foobar?foo=bar"
    req = Kronk::Request.parse(raw)

    assert_equal Kronk::Request, req.class
    assert_equal URI.parse("http://localhost:3000/foobar?foo=bar"), req.uri
  end


  def test_parse_invalid
    assert_raises Kronk::Request::ParseError do
      Kronk::Request.parse "thing\nfoo\n"
    end
    assert_raises Kronk::Request::ParseError do
      Kronk::Request.parse ""
    end
  end


  def test_parse_to_hash
    expected = {:path => "/foobar"}
    assert_equal expected, Kronk::Request.parse_to_hash("/foobar")

    expected = {:http_method => "GET", :path => "/foobar"}
    assert_equal expected, Kronk::Request.parse_to_hash("GET /foobar")

    expected.merge! :host => "example.com"
    raw = "GET /foobar\r\nHost: example.com"
    assert_equal expected, Kronk::Request.parse_to_hash(raw)

    expected.merge! :http_method => "POST",
                    :data        => "foo=bar",
                    :headers     => {'Accept' => 'json'}

    raw = "POST /foobar\r\nAccept: json\r\nHost: example.com\r\n\r\nfoo=bar"
    assert_equal expected, Kronk::Request.parse_to_hash(raw)
  end


  def test_parse_to_hash_url
    expected = {:host => "http://example.com", :path => "/foobar?foo=bar"}
    assert_equal expected,
      Kronk::Request.parse_to_hash("http://example.com/foobar?foo=bar")
  end


  def test_parse_to_hash_invalid
    assert_nil Kronk::Request.parse_to_hash("thing\nfoo\n")
    assert_nil Kronk::Request.parse_to_hash("")
  end


  def test_retrieve_post
    expect_request "POST", "http://example.com/request/path?foo=bar",
      :data    => {'test' => 'thing'},
      :headers => {'X-THING' => 'thing'}

    resp = Kronk::Request.new("http://example.com/request/path?foo=bar",
            :data => 'test=thing', :headers => {'X-THING' => 'thing'},
            :http_method => :post).retrieve

    assert_equal mock_200_response, resp.raw
  end


  def test_build_uri
    uri = Kronk::Request.build_uri "https://example.com"
    assert_equal URI.parse("https://example.com"), uri
  end


  def test_build_uri_string
    uri = Kronk::Request.build_uri "example.com"
    assert_equal "http://example.com/", uri.to_s
  end


  def test_build_uri_localhost
    uri = Kronk::Request.build_uri "/path/to/resource"
    assert_equal "http://localhost:3000/path/to/resource", uri.to_s
  end


  def test_build_uri_query_hash
    query = {'a' => '1', 'b' => '2'}
    uri   = Kronk::Request.build_uri "example.com/path", :query => query

    assert_equal query, Kronk::Request.parse_nested_query(uri.query)
  end


  def test_build_uri_query_hash_str
    query = {'a' => '1', 'b' => '2'}
    uri   = Kronk::Request.build_uri "example.com/path?c=3", :query => query

    assert_equal({'a' => '1', 'b' => '2', 'c' => '3'},
      Kronk::Request.parse_nested_query(uri.query))
  end


  def test_build_uri_suffix
    uri = Kronk::Request.build_uri "http://example.com/path",
             :uri_suffix => "/to/resource"

    assert_equal "http://example.com/path/to/resource", uri.to_s
  end


  def test_build_path
    uri = Kronk::Request.build_uri "http://example.com/",
             :path       => "/path",
             :uri_suffix => "/to/resource"

    assert_equal "http://example.com//path/to/resource", uri.to_s
  end


  def test_build_uri_from_uri
    query = {'a' => '1', 'b' => '2'}
    uri   = Kronk::Request.build_uri URI.parse("http://example.com/path"),
              :query => query, :uri_suffix => "/to/resource"

    assert_equal "example.com",       uri.host
    assert_equal "/path/to/resource", uri.path
    assert_equal query, Kronk::Request.parse_nested_query(uri.query)
  end


  def test_body_hash
    req = Kronk::Request.new "foo.com"
    req.headers['Transfer-Encoding'] = "chunked"
    req.body = {:foo => :bar}
    req = req.http_request

    assert_equal "foo=bar", req.body
    assert_equal 'chunked', req['Transfer-Encoding']
    assert_equal "application/x-www-form-urlencoded", req['Content-Type']
  end


  def test_body_string
    req = Kronk::Request.new "foo.com", :form => "blah"
    req.headers['Transfer-Encoding'] = "chunked"
    req.body = "foo=bar"
    req = req.http_request

    assert_equal "foo=bar", req.body
    assert_equal 'chunked', req['Transfer-Encoding']
    assert_equal '7', req['Content-Length']
    assert_equal "application/x-www-form-urlencoded", req['Content-Type']
  end


  def test_body_string_io
    req = Kronk::Request.new "foo.com"
    req.body = str_io = StringIO.new("foo=bar")
    req = req.http_request

    assert_equal str_io,               req.body_stream
    assert_equal nil,                  req['Transfer-Encoding']
    assert_equal 'application/binary', req['Content-Type']
    assert_equal '7',                  req['Content-Length']
  end


  def test_body_nil
    req = Kronk::Request.new "foo.com"
    req.body = nil
    req = req.http_request

    assert_equal nil, req.body_stream
    assert_equal "",  req.body
    assert_equal nil, req['Transfer-Encoding']
    assert_equal nil, req['Content-Type']
    assert_equal '0', req['Content-Length']
  end


  def test_body_io
    req = Kronk::Request.new "foo.com"
    io, = IO.pipe
    req.body = io
    req = req.http_request

    assert_equal io,                   req.body_stream
    assert_equal 'chunked',            req['Transfer-Encoding']
    assert_equal 'application/binary', req['Content-Type']
    assert_equal nil,                  req['Content-Length']
  end


  def test_body_file_io
    io  = File.open 'Manifest.txt', 'r'
    req = Kronk::Request.new "foo.com"
    req.body = io
    req = req.http_request

    assert_equal io,           req.body_stream
    assert_equal nil,          req['Transfer-Encoding']
    assert_equal 'text/plain', req['Content-Type']
    assert_equal io.size.to_s, req['Content-Length']

  ensure
    io.close
  end


  def test_body_other
    req = Kronk::Request.new "foo.com"
    req.headers['Transfer-Encoding'] = "chunked"
    req.body = 12345
    req = req.http_request

    assert_equal "12345",   req.body
    assert_equal "chunked", req['Transfer-Encoding']
    assert_equal nil,       req['Content-Type']
  end


  def test_retrieve_get
    expect_request "GET", "http://example.com/request/path?foo=bar"
    resp =
      Kronk::Request.new("http://example.com/request/path?foo=bar").retrieve

    assert_equal mock_200_response, resp.raw
  end


  def test_retrieve_cookies
    Kronk.cookie_jar.expects(:get_cookie_header).returns "mock_cookie"

    expect_request "GET", "http://example.com/request/path?foo=bar",
      :headers => {'Cookie' => "mock_cookie", 'User-Agent' => "kronk"}

    Kronk::Request.new("http://example.com/request/path",
            :query => "foo=bar", :headers => {'User-Agent' => "kronk"}).retrieve
  end


  def test_retrieve_no_cookies_found
    Kronk.cookie_jar.expects(:get_cookie_header).
      with("http://example.com/request/path?foo=bar").returns ""

    expect_request "GET", "http://example.com/request/path?foo=bar",
      :headers => {'User-Agent' => "kronk"}

    Kronk::Request.new("http://example.com/request/path",
            :query => "foo=bar", :headers => {'User-Agent' => "kronk"}).retrieve
  end


  def test_retrieve_no_cookies
    Kronk.cookie_jar.expects(:get_cookie_header).
      with("http://example.com/request/path?foo=bar").never

    Kronk.cookie_jar.expects(:add_cookie).never

    expect_request "GET", "http://example.com/request/path?foo=bar",
      :headers => {'User-Agent' => "kronk"}

    Kronk::Request.new("http://example.com/request/path",
            :query => "foo=bar", :headers => {'User-Agent' => "kronk"},
            :no_cookies => true).retrieve
  end


  def test_retrieve_no_cookies_config
    old_config = Kronk.config[:use_cookies]
    Kronk.config[:use_cookies] = false

    Kronk.cookie_jar.expects(:get_cookie_header).
      with("http://example.com/request/path?foo=bar").never

    Kronk.cookie_jar.expects(:set_cookies_from_headers).never

    expect_request "GET", "http://example.com/request/path?foo=bar",
      :headers => {'User-Agent' => "kronk"}

    Kronk::Request.new("http://example.com/request/path",
            :query => "foo=bar", :headers => {'User-Agent' => "kronk"}).retrieve

    Kronk.config[:use_cookies] = old_config
  end


  def test_retrieve_no_cookies_config_override
    old_config = Kronk.config[:use_cookies]
    Kronk.config[:use_cookies] = false

    Kronk.cookie_jar.expects(:get_cookie_header).
      with("http://example.com/request/path?foo=bar").returns ""

    expect_request "GET", "http://example.com/request/path?foo=bar",
      :headers => {'User-Agent' => "kronk"}

    Kronk::Request.new("http://example.com/request/path",
            :query => "foo=bar", :headers => {'User-Agent' => "kronk"},
            :no_cookies => false).retrieve

    Kronk.config[:use_cookies] = old_config
  end


  def test_retrieve_cookies_already_set
    Kronk.cookie_jar.expects(:get_cookie_header).
      with("http://example.com/request/path?foo=bar").never

    expect_request "GET", "http://example.com/request/path?foo=bar",
      :headers => {'User-Agent' => "kronk"}

    Kronk::Request.new("http://example.com/request/path",
            :query => "foo=bar",
            :headers => {'User-Agent' => "kronk", 'Cookie' => "mock_cookie"},
            :no_cookies => true).retrieve
  end


  def test_retrieve_query
    expect_request "GET", "http://example.com/path?foo=bar"
    Kronk::Request.new("http://example.com/path",
      :query => {:foo => :bar}).retrieve
  end


  def test_retrieve_query_appended
    expect_request "GET", "http://example.com/path?foo=bar&test=thing"
    Kronk::Request.new("http://example.com/path?foo=bar",
      :query => {:test => :thing}).retrieve
  end


  def test_retrieve_query_appended_string
    expect_request "GET", "http://example.com/path?foo=bar&test=thing"
    Kronk::Request.new("http://example.com/path?foo=bar",
      :query => "test=thing").retrieve
  end


  def test_oauth
    oauth = {
      :token => "blah",
      :token_secret => "tsecret",
      :consumer_key => "ckey",
      :consumer_secret => "csecret"
    }

    req = Kronk::Request.new "foo.com", :oauth => oauth
    auth = req.http_request['Authorization']

    assert auth =~ /^OAuth\s/,
      ":oauth option should have triggered Authorization header"

    assert auth =~ / oauth_consumer_key="ckey"/,
      "Authorization should have the consumer key"
    assert auth =~ / oauth_token="blah"/,
      "Authorization should have token"
  end


  def test_oauth_basic_auth_collision
    oauth = {
      :token => "blah",
      :token_secret => "tsecret",
      :consumer_key => "ckey",
      :consumer_secret => "csecret"
    }

    req = Kronk::Request.new "foo.com", :oauth => oauth,
            :auth => {:username => "foo", :password => "bar"}

    assert_equal({:username => "foo", :password => "bar"}, req.auth)
    assert_equal(oauth, req.oauth)

    auth = req.http_request['Authorization']

    assert auth =~ /^OAuth\s/,
      ":oauth option should have triggered Authorization header"

    assert auth =~ / oauth_consumer_key="ckey"/,
      "Authorization should have the consumer key"
    assert auth =~ / oauth_token="blah"/,
      "Authorization should have token"
  end


  def test_oauth_from_headers
    oauth = "OAuth oauth_consumer_key=\"ckey\", \
      oauth_nonce=\"e95a6580533f4b122dc1b67bf28ea320\", \
      oauth_signature=\"NLYgre5962QIYBQFjCQdt5nymBc%3D\", \
      oauth_signature_method=\"HMAC-SHA1\", \
      oauth_timestamp=\"1344556946\", \
      oauth_token=\"blah\", \
      oauth_version=\"1.0\""

    req = Kronk::Request.new "foo.com", :headers => {'Authorization' => oauth}
    auth = req.http_request['Authorization']

    assert auth =~ /^OAuth\s/,
      ":oauth option should have triggered Authorization header"

    assert auth =~ / oauth_consumer_key="ckey"/,
      "Authorization should have the consumer key"
    assert auth =~ / oauth_token="blah"/,
      "Authorization should have token"
  end


  def test_oauth_from_headers_and_opts
    oauth = "OAuth oauth_consumer_key=\"ckey\", \
      oauth_nonce=\"e95a6580533f4b122dc1b67bf28ea320\", \
      oauth_signature=\"NLYgre5962QIYBQFjCQdt5nymBc%3D\", \
      oauth_signature_method=\"HMAC-SHA1\", \
      oauth_timestamp=\"1344556946\", \
      oauth_token=\"blah\", \
      oauth_version=\"1.0\""

    oath_opt = {
    }

    req = Kronk::Request.new "foo.com/bar",
      :oauth   => {:token => "newtoken"},
      :headers => {'Authorization' => oauth}

    auth = req.http_request['Authorization']

    assert auth =~ /^OAuth\s/,
      ":oauth option should have triggered Authorization header"

    assert auth =~ / oauth_consumer_key="ckey"/,
      "Authorization should have the consumer key"
    assert auth =~ / oauth_token="newtoken"/,
      "Authorization should have token"
  end


  def test_auth_from_headers
    req = Kronk::Request.parse File.read("test/mocks/get_request.txt")
    assert_equal "bob",    req.auth[:username]
    assert_equal "foobar", req.auth[:password]
  end


  def test_auth_from_headers_and_options
    req = Kronk::Request.new "http://example.com/path",
            :headers => {"Authorization" => "Basic Ym9iOmZvb2Jhcg=="},
            :auth    => {:password => "password"}
    assert_equal "bob",      req.auth[:username]
    assert_equal "password", req.auth[:password]
  end


  def test_retrieve_basic_auth
    auth_opts = {:username => "user", :password => "pass"}

    expect_request "GET", "http://example.com" do |http, req, resp|
      req.expects(:basic_auth).with auth_opts[:username], auth_opts[:password]
    end

    Kronk::Request.new("http://example.com", :auth => auth_opts).retrieve
  end


  def test_retrieve_bad_basic_auth
    auth_opts = {:password => "pass"}

    expect_request "GET", "http://example.com" do |http, req, resp|
      req.expects(:basic_auth).with(auth_opts[:username], auth_opts[:password]).
        never
    end

    Kronk::Request.new("http://example.com", :auth => auth_opts).retrieve
  end


  def test_retrieve_no_basic_auth
    expect_request "GET", "http://example.com" do |http, req, resp|
      req.expects(:basic_auth).never
    end

    Kronk::Request.new("http://example.com").retrieve
  end


  def test_retrieve_ssl
    expect_request "GET", "https://example.com", :ssl => true

    resp = Kronk::Request.new("https://example.com").retrieve

    assert_equal mock_200_response, resp.raw
  end


  def test_retrieve_no_ssl
    expect_request "GET", "http://example.com" do |http, req, resp|
      req.expects(:use_ssl=).with(true).never
    end

    resp = Kronk::Request.new("http://example.com").retrieve

    assert_equal mock_200_response, resp.raw
  end


  def test_form_option
    req = Kronk::Request.new("http://example.com", :data => "foo",
                              :form => "bar")

    assert_equal "bar", req.body
    assert_equal "application/x-www-form-urlencoded",
                  req.headers['Content-Type']
  end


  def test_form_data
    req = Kronk::Request.new("http://example.com", :data => "foo",
                              :form => "bar")

    assert_equal "bar", req.body
    assert_equal "application/x-www-form-urlencoded",
                  req.headers['Content-Type']
  end


  def test_retrieve_user_agent_default
    expect_request "GET", "http://example.com",
    :headers => {
      'User-Agent' => Kronk::DEFAULT_USER_AGENT
    }

    Kronk::Request.new("http://example.com").retrieve
  end


  def test_retrieve_user_agent_alias
    expect_request "GET", "http://example.com",
    :headers => {'User-Agent' => "Mozilla/5.0 (compatible; Konqueror/3; Linux)"}

    Kronk::Request.new("http://example.com",
             :user_agent => 'linux_konqueror').retrieve
  end


  def test_retrieve_user_agent_custom
    expect_request "GET", "http://example.com",
    :headers => {'User-Agent' => "custom user agent"}

    Kronk::Request.new("http://example.com",
             :user_agent => 'custom user agent').retrieve
  end


  def test_retrieve_user_agent_header_already_set
    expect_request "GET", "http://example.com",
    :headers => {'User-Agent' => "custom user agent"}

    Kronk::Request.new("http://example.com",
             :user_agent => 'mac_safari',
             :headers    => {'User-Agent' => "custom user agent"}).retrieve
  end


  def test_retrieve_proxy
    proxy = {
      :host     => "proxy.com",
      :username => "john",
      :password => "smith"
    }

    expect_request "GET", "http://example.com", :proxy => proxy

    Kronk::Request.new("http://example.com", :proxy => proxy).retrieve
  end


  def test_retrieve_proxy_string
    proxy = "proxy.com:8888"

    expect_request "GET", "http://example.com",
      :proxy => {:host => 'proxy.com', :port => "8888"}

    Kronk::Request.new("http://example.com", :proxy => proxy).retrieve
  end


  def test_proxy_string
    proxy_class = Kronk::Request.new("host.com", :proxy => "myproxy.com:80").
                    connection.class

    assert_equal "myproxy.com",
      proxy_class.instance_variable_get("@proxy_address")

    assert_equal '80', proxy_class.instance_variable_get("@proxy_port")

    assert_nil proxy_class.instance_variable_get("@proxy_user")
    assert_nil proxy_class.instance_variable_get("@proxy_pass")
  end


  def test_proxy_no_port
    proxy_class = Kronk::Request.new("host.com", :proxy => "myproxy.com").
                    connection.class

    assert_equal "myproxy.com",
      proxy_class.instance_variable_get("@proxy_address")

    assert_equal 8080, proxy_class.instance_variable_get("@proxy_port")

    assert_nil proxy_class.instance_variable_get("@proxy_user")
    assert_nil proxy_class.instance_variable_get("@proxy_pass")
  end


  def test_proxy_hash
    req = Kronk::Request.new "http://example.com",
            :proxy => { :host     => "myproxy.com",
                        :port     => 8080,
                        :username => "john",
                        :password => "smith" }

    proxy_class = req.connection.class

    assert_equal "myproxy.com",
      proxy_class.instance_variable_get("@proxy_address")

    assert_equal 8080, proxy_class.instance_variable_get("@proxy_port")

    assert_equal "john", proxy_class.instance_variable_get("@proxy_user")
    assert_equal "smith", proxy_class.instance_variable_get("@proxy_pass")
  end


  def test_build_query_hash
    hash = {
      :foo => :bar,
      :a => ['one', 'two'],
      :b => {:b1 => [1,2], :b2 => "test"}
    }

    assert_equal "a[]=one&a[]=two&b[b1][]=1&b[b1][]=2&b[b2]=test&foo=bar",
                  Kronk::Request.build_query(hash).split("&").sort.join("&")
  end


  def test_build_query_non_hash
    assert_equal [1,2,3].to_s, Kronk::Request.build_query([1,2,3])

    assert_equal "q[]=1&q[]=2&q[]=3", Kronk::Request.build_query([1,2,3], "q")
    assert_equal "key=val", Kronk::Request.build_query("val", "key")
  end


  def test_vanilla_request
    req = Kronk::Request::VanillaRequest.new :my_http_method,
            "some/path", 'User-Agent' => 'vanilla kronk'

    assert Net::HTTPRequest === req
    assert_equal "MY_HTTP_METHOD", req.class::METHOD
    assert req.class::REQUEST_HAS_BODY
    assert req.class::RESPONSE_HAS_BODY

    assert_equal "some/path", req.path
    assert_equal "vanilla kronk", req['User-Agent']
  end


  def test_multipart_hash
    file1 = File.open("test/mocks/200_gzip.txt", "rb")
    file2 = File.open("test/mocks/200_response.json", "rb")
    File.stubs(:open).with("test/mocks/200_gzip.txt", "rb").returns file1
    File.stubs(:open).with("test/mocks/200_response.json", "rb").returns file2

    req = Kronk::Request.new "host.com",
            :form => {:foo => ["bar"]},
            :form_upload => {:foo => ["test/mocks/200_gzip.txt"],
              :bar => "test/mocks/200_response.json"}

    assert_equal Kronk::Multipart, req.body.class
    assert_equal 3, req.body.parts.length

    expected = [{"content-disposition"=>"form-data; name=\"foo[]\""}, "bar"]
    assert req.body.parts.include?(expected),
      "Request body should include foo[]=bar"

    expected = [{
      'content-disposition' =>
        "form-data; name=\"foo[]\"; filename=\"#{File.basename file1.path}\"",
      'Content-Type'        => "text/plain",
      'Content-Transfer-Encoding' => 'binary'
    }, file1]
    assert req.body.parts.include?(expected),
      "Request body should include foo[]=#{file1.inspect}"

    expected = [{
      'content-disposition' =>
        "form-data; name=\"bar\"; filename=\"#{File.basename file2.path}\"",
      'Content-Type'        => "application/json",
      'Content-Transfer-Encoding' => 'binary'
    }, file2]
    assert req.body.parts.include?(expected),
      "Request body should include bar=#{file2.inspect}"

  ensure
    file1.close
    file2.close
  end


  def test_multipart_string
    file1 = File.open("test/mocks/200_gzip.txt", "rb")
    file2 = File.open("test/mocks/200_response.json", "rb")
    File.stubs(:open).with("test/mocks/200_gzip.txt", "rb").returns file1
    File.stubs(:open).with("test/mocks/200_response.json", "rb").returns file2

    req = Kronk::Request.new "host.com",
            :form        => "foo[]=bar",
            :form_upload =>
              "foo[]=test/mocks/200_gzip.txt&bar=test/mocks/200_response.json"

    assert_equal Kronk::Multipart, req.body.class
    assert_equal 3, req.body.parts.length

    expected = [{"content-disposition"=>"form-data; name=\"foo[]\""}, "bar"]
    assert req.body.parts.include?(expected),
      "Request body should include foo[]=bar"

    expected = [{
      'content-disposition' =>
        "form-data; name=\"foo[]\"; filename=\"#{File.basename file1.path}\"",
      'Content-Type'        => "text/plain",
      'Content-Transfer-Encoding' => 'binary'
    }, file1]
    assert req.body.parts.include?(expected),
      "Request body should include foo[]=#{file1.inspect}"

    expected = [{
      'content-disposition' =>
        "form-data; name=\"bar\"; filename=\"#{File.basename file2.path}\"",
      'Content-Type'        => "application/json",
      'Content-Transfer-Encoding' => 'binary'
    }, file2]
    assert req.body.parts.include?(expected),
      "Request body should include bar=#{file2.inspect}"

  ensure
    file1.close
    file2.close
  end


  def test_http_request_multipart
    file1 = File.open("test/mocks/200_gzip.txt", "rb")
    file2 = File.open("test/mocks/200_response.json", "rb")
    File.stubs(:open).with("test/mocks/200_gzip.txt", "rb").returns file1
    File.stubs(:open).with("test/mocks/200_response.json", "rb").returns file2

    req = Kronk::Request.new "host.com",
            :form        => "foo[]=bar",
            :form_upload =>
              "foo[]=test/mocks/200_gzip.txt&bar=test/mocks/200_response.json"

    hreq = req.http_request
    assert_equal Kronk::MultipartIO, hreq.body_stream.class
    assert_equal req.body.to_io.size.to_s, hreq['Content-Length']
    assert_equal 5, hreq.body_stream.parts.length
    assert hreq.body_stream.parts.include?(file1),
      "HTTPRequest body stream should include #{file1.inspect}"
    assert hreq.body_stream.parts.include?(file2),
      "HTTPRequest body stream should include #{file2.inspect}"

  ensure
    file1.close
    file2.close
  end
end
