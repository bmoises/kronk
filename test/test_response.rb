require 'test/test_helper'
require 'zlib'

class TestResponse < Test::Unit::TestCase

  def setup
    @html_resp  = Kronk::Response.read_file "test/mocks/200_response.txt"
    @json_resp  = Kronk::Response.read_file "test/mocks/200_response.json"
    @plist_resp = Kronk::Response.read_file "test/mocks/200_response.plist"
    @xml_resp   = Kronk::Response.read_file "test/mocks/200_response.xml"
  end


  def test_ext
    assert_equal "html",  @html_resp.ext
    assert_equal "json",  @json_resp.ext
    assert_equal "plist", @plist_resp.ext
    assert_equal "xml",   @xml_resp.ext
  end


  def test_ext_file
    yml = Kronk::Response.
        read_file("test/mocks/cookies.yml", :allow_headless => true)

    assert_equal "text/x-yaml; charset=ASCII-8BIT", yml.headers['content-type']
    assert_equal "yaml", yml.ext

    yml.headers.delete('content-type')
    assert_equal "yml", yml.ext
  end


  def test_ext_default
    bin = Kronk::Response.
        read_file("bin/kronk", :allow_headless => true)

    assert_equal "text/plain; charset=ASCII-8BIT", bin.headers['content-type']
    assert_equal "txt", bin.ext

    bin.headers.delete('content-type')
    assert_equal "txt", bin.ext
  end


  def test_init_encoding
    assert_equal "ISO-8859-1", @html_resp.encoding.to_s
    assert_equal "ISO-8859-1", @html_resp.body.encoding.to_s if
      "".respond_to? :encoding
    assert_equal "UTF-8",      @json_resp.encoding.to_s.upcase

    png = Kronk::Response.read_file "test/mocks/200_response.png"
    assert_equal "ASCII-8BIT", png.encoding.to_s
  end


  def test_init_cookies
    Kronk.cookie_jar.expects(:add_cookie).twice

    html_resp = Kronk::Response.new File.read("test/mocks/200_response.txt"),
                  :request    => Kronk::Request.new("http://google.com"),
                  :no_cookies => false

    expected_cookies =
      [{"name"=>"PREF",
        "value"=>
         "ID=99d644506f26d85e:FF=0:TM=1290788168:LM=1290788168:S=VSMemgJxlmlToFA3",
        "domain"=>".google.com",
        "path"=>"/",
        "expires_at"=>Time.parse("2012-11-25 08:16:08 -0800")},
       {"name"=>"NID",
        "value"=>
         "41=CcmNDE4SfDu5cdTOYVkrCVjlrGO-oVbdo1awh_p8auk2gI4uaX1vNznO0QN8nZH4Mh9WprRy3yI2yd_Fr1WaXVru6Xq3adlSLGUTIRW8SzX58An2nH3D2PhAY5JfcJrl",
        "domain"=>".google.com",
        "path"=>"/",
        "expires_at"=>Time.parse("2011-05-28 09:16:08 -0700"),
        "http_only"=>true
      }]

    assert_equal expected_cookies, html_resp.cookies
  end


  def test_init_no_cookies_opt
    Kronk.cookie_jar.expects(:add_cookie).never

    req = Kronk::Request.new("http://google.com")

    html_resp = Kronk::Response.new File.read("test/mocks/200_response.txt"),
                  :request    => req,
                  :no_cookies => true

    expected_cookies =
      [{"name"=>"PREF",
        "value"=>
         "ID=99d644506f26d85e:FF=0:TM=1290788168:LM=1290788168:S=VSMemgJxlmlToFA3",
        "domain"=>".google.com",
        "path"=>"/",
        "expires_at"=>Time.parse("2012-11-25 08:16:08 -0800")},
       {"name"=>"NID",
        "value"=>
         "41=CcmNDE4SfDu5cdTOYVkrCVjlrGO-oVbdo1awh_p8auk2gI4uaX1vNznO0QN8nZH4Mh9WprRy3yI2yd_Fr1WaXVru6Xq3adlSLGUTIRW8SzX58An2nH3D2PhAY5JfcJrl",
        "domain"=>".google.com",
        "path"=>"/",
        "expires_at"=>Time.parse("2011-05-28 09:16:08 -0700"),
        "http_only"=>true
      }]

    assert_equal expected_cookies, html_resp.cookies
  end


  def test_body
    expected = File.read("test/mocks/200_response.json").split("\r\n\r\n")[1]
    assert_equal expected,
                 @json_resp.body
  end


  def test_body_yield
    count    = 0
    expected = File.read("test/mocks/200_response.json").split("\r\n\r\n")[1]
    body     = ""

    json_file = File.open "test/mocks/200_response.json", "r"

    with_buffer_size 64 do
      json_resp = Kronk::Response.new json_file
      json_resp.content_length = nil
      json_resp.body do |chunk|
        count += 1
        body << chunk
      end
    end

    json_file.close

    assert_equal 15, count
    assert_equal expected, body
  end


  def test_body_yield_exception
    count    = 0
    expected = File.read("test/mocks/200_response.json").split("\r\n\r\n")[1]
    body     = ""

    json_file = File.open "test/mocks/200_response.json", "r"

    with_buffer_size 64 do
      json_resp = Kronk::Response.new json_file
      json_resp.content_length = nil
      json_resp.body do |chunk|
        count += 1
        body << chunk
        raise IOError if count == 2
      end
    end

    json_file.close

    assert_equal 3, count
    assert_equal expected, body
  end


  def test_body_yield_inflate
    count    = 0
    expected = File.read("test/mocks/200_inflate.txt")
    expected.force_encoding('binary') if expected.respond_to?(:force_encoding)
    expected = expected.split("\r\n\r\n")[1]
    expected = Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(expected)
    body     = ""

    json_file = File.open "test/mocks/200_inflate.txt", "r"

    with_buffer_size 64 do
      json_resp = Kronk::Response.new json_file
      json_resp.content_length = nil
      json_resp.body do |chunk|
        count += 1
        body << chunk
      end
    end

    json_file.close

    assert_equal 1, count
    assert_equal expected, body
  end


  def test_body_yield_gzip
    count    = 0
    expected = File.read("test/mocks/200_gzip.txt")
    expected.force_encoding('binary') if expected.respond_to?(:force_encoding)
    expected = expected.split("\r\n\r\n")[1]
    expected = Zlib::GzipReader.new(StringIO.new(expected)).read
    body     = ""

    json_file = File.open "test/mocks/200_gzip.txt", "r"

    with_buffer_size 64 do
      json_resp = Kronk::Response.new json_file
      json_resp.content_length = nil
      json_resp.body do |chunk|
        count += 1
        body << chunk
      end
    end

    json_file.close

    assert_equal 19, count
    assert_equal expected, body
  end


  def test_body_yield_gzip_exception
    count    = 0
    expected = File.read("test/mocks/200_gzip.txt")
    expected.force_encoding('binary') if expected.respond_to?(:force_encoding)
    expected = expected.split("\r\n\r\n")[1]
    expected = Zlib::GzipReader.new(StringIO.new(expected)).read
    body     = ""

    gzip_file = File.open "test/mocks/200_gzip.txt", "r"

    with_buffer_size 64 do
      gzip_resp = Kronk::Response.new gzip_file
      gzip_resp.body do |chunk|
        count += 1
        body << chunk
        raise IOError if count == 3
      end
    end

    gzip_file.close

    assert_equal 4, count
    assert_equal expected, body
  end


  def test_bytes
    png = Kronk::Response.read_file "test/mocks/200_response.png"
    assert_equal 8469, png.bytes
    assert_equal png['Content-Length'].to_i, png.bytes

    headless = Kronk::Response.new "foobar"
    assert_equal "foobar".bytes.count, headless.bytes
  end


  def test_byterate
    @html_resp.time = 10
    assert_equal 930.3, @html_resp.byterate
    @html_resp.time = 100
    assert_equal 93.03, @html_resp.byterate
  end


  def test_total_bytes
    assert_equal @html_resp.raw.bytes.count, @html_resp.total_bytes
  end


  def test_cookie
    assert_nil @html_resp.cookie
    @html_resp['Cookie'] = "blahblahblah"
    assert_equal "blahblahblah", @html_resp.cookie
  end


  def test_headless
    assert Kronk::Response.new("blah blah blah").headless?,
      "Expected a headless HTTP response"

    assert !Kronk::Response.new("HTTP/1.1 200 OK\r\n\r\nHI").headless?,
      "Expected full valid HTTP response"
  end


  def test_new_from_one_line_io
    io   = StringIO.new "just this one line!"
    resp = Kronk::Response.new io

    assert_equal "just this one line!", resp.body
    enc = "".encoding rescue "ASCII-8BIT"
    assert_equal "text/plain; charset=#{enc}", resp['Content-Type']
  end


  def test_read_file
    resp = Kronk::Response.read_file "test/mocks/200_response.txt"

    expected_header = "#{mock_200_response.split("\r\n\r\n", 2)[0]}\r\n"

    assert_equal mock_200_response, resp.raw
    assert_equal expected_header, resp.raw_header
  end


  def test_parsed_body_json
    raw = File.read "test/mocks/200_response.json"
    expected = JSON.parse raw.split("\r\n\r\n")[1]

    assert_equal expected, @json_resp.parsed_body
    assert_equal @xml_resp.parsed_body, @json_resp.parsed_body

    assert_raises Kronk::ParserError do
      @json_resp.parsed_body Kronk::PlistParser
    end
  end


  def test_parsed_body_string_parser
    raw = File.read "test/mocks/200_response.json"
    expected = JSON.parse raw.split("\r\n\r\n")[1]

    assert_equal expected, @json_resp.parsed_body

    assert_raises Kronk::ParserError do
      @json_resp.parsed_body 'PlistParser'
    end
  end


  def test_parsed_body_plist
    raw = File.read "test/mocks/200_response.plist"
    expected = Kronk::PlistParser.parse raw.split("\r\n\r\n")[1]

    assert_equal expected, @plist_resp.parsed_body
    assert_equal @json_resp.parsed_body, @plist_resp.parsed_body
  end


  def test_parsed_body_xml
    raw = File.read "test/mocks/200_response.xml"
    expected = Kronk::XMLParser.parse raw.split("\r\n\r\n")[1]

    assert_equal expected, @xml_resp.parsed_body
    assert_equal @json_resp.parsed_body, @xml_resp.parsed_body
  end


  def test_parsed_body_missing_parser
    assert_raises Kronk::Response::MissingParser do
      @html_resp.parsed_body
    end
  end


  def test_parsed_body_invalid_parser
    assert_raises Kronk::Response::InvalidParser do
      @html_resp.parsed_body "FooBar"
    end
  end


  def test_parsed_body_bad_parser
    assert_raises Kronk::ParserError do
      @html_resp.parsed_body JSON
    end
  end


  def test_parsed_header
    parsed_headers = @json_resp.to_hash.merge(
                        'http-version' => '1.1',
                        'status'       => '200')

    assert_equal parsed_headers, @json_resp.parsed_header

    assert_equal({'content-type' => "application/json; charset=utf-8"},
                @json_resp.parsed_header('Content-Type'))

    assert_equal({'date'         => "Fri, 03 Dec 2010 21:49:00 GMT",
                  'content-type' => "application/json; charset=utf-8"},
                @json_resp.parsed_header(['Content-Type', 'Date']))

    assert_nil @json_resp.parsed_header(false)
    assert_nil @json_resp.parsed_header(nil)
  end


  def test_raw_header
    assert_equal "#{@json_resp.raw.split("\r\n\r\n")[0]}\r\n",
                 @json_resp.raw_header

    assert_equal "Content-Type: application/json; charset=utf-8\r\n",
                 @json_resp.raw_header('Content-Type')

    assert_equal "Date: Fri, 03 Dec 2010 21:49:00 GMT\r\nContent-Type: application/json; charset=utf-8\r\n",
                @json_resp.raw_header(['Content-Type', 'Date'])

    assert_nil @json_resp.raw_header(false)
    assert_nil @json_resp.raw_header(nil)
  end


  def test_to_s
    body = @json_resp.raw
    assert_equal body, @json_resp.to_s
  end


  def test_to_s_no_body
    @json_resp.raw.split("\r\n\r\n")[1]

    assert_equal "", @json_resp.to_s(:body => false, :headers => false)

    assert_equal "#{@json_resp.raw.split("\r\n\r\n")[0]}\r\n",
                 @json_resp.to_s(:body => false)
  end


  def test_to_s_single_header
    body = @json_resp.raw.split("\r\n\r\n")[1]

    expected = "Content-Type: application/json; charset=utf-8\r\n\r\n#{body}"
    assert_equal expected, @json_resp.to_s(:headers => "Content-Type")
  end


  def test_to_s_multiple_headers
    body = @json_resp.raw.split("\r\n\r\n")[1]

    expected = "Date: Fri, 03 Dec 2010 21:49:00 GMT\r\nContent-Type: application/json; charset=utf-8\r\n\r\n#{body}"
    assert_equal expected, @json_resp.to_s(:headers => ["Content-Type", "Date"])

    expected = "Date: Fri, 03 Dec 2010 21:49:00 GMT\r\nContent-Type: application/json; charset=utf-8\r\n"
    assert_equal expected,
      @json_resp.to_s(:body => false, :headers => ["Content-Type", "Date"])
  end


  def test_data
    body = JSON.parse @json_resp.body
    @json_resp.to_hash

    assert_equal body, @json_resp.data

    assert_nil @json_resp.data(:no_body => true, :show_headers => false)

    assert_equal "#{@json_resp.raw.split("\r\n\r\n")[0]}\r\n",
                 @json_resp.to_s(:body => false)
  end


  def test_data_parser
    assert_raises Kronk::ParserError do
      @json_resp.data :parser => Kronk::PlistParser
    end

    assert @json_resp.data(:parser => JSON)
  end


  def test_data_single_header
    body = JSON.parse @json_resp.body
    expected =
      [{'content-type' => 'application/json; charset=utf-8'}, body]

    assert_equal expected,
                 @json_resp.data(:show_headers => "Content-Type")
  end


  def test_data_multiple_headers
    body = JSON.parse @json_resp.body
    expected =
      [{'content-type' => 'application/json; charset=utf-8',
        'date'         => "Fri, 03 Dec 2010 21:49:00 GMT"
      }, body]

    assert_equal expected,
                 @json_resp.data(
                    :show_headers => ["Content-Type", "Date"])
  end


  def test_data_no_body
    expected = {
        'content-type' => 'application/json; charset=utf-8',
        'date'         => "Fri, 03 Dec 2010 21:49:00 GMT"
      }

    assert_equal expected,
                 @json_resp.data(:no_body => true,
                    :show_headers => ["Content-Type", "Date"])
  end


  def test_data_only_data
    expected = {"business"        => {"id" => "1234"},
                "original_request"=> {"id"=>"1234"}}

    assert_equal expected,
      @json_resp.data(:only_data => "**/id")
  end


  def test_data_multiple_only_data
    expected = {"business"    => {"id" => "1234"},
                "request_id"  => "mock_rid"}

    assert_equal expected,
      @json_resp.data(:only_data => ["business/id", "request_id"])
  end


  def test_data_ignore_data
    expected = JSON.parse @json_resp.body
    expected['business'].delete 'id'
    expected['original_request'].delete 'id'

    assert_equal expected,
      @json_resp.data(:ignore_data => "**/id")
  end


  def test_data_multiple_ignore_data
    expected = JSON.parse @json_resp.body
    expected['business'].delete 'id'
    expected.delete 'request_id'

    assert_equal expected,
      @json_resp.data(:ignore_data => ["business/id", "request_id"])
  end


  def test_data_collected_and_ignored
    expected = {"business" => {"id" => "1234"}}

    assert_equal expected,
      @json_resp.data(:only_data => "**/id",
        :ignore_data => "original_request")
  end


  def test_redirect?
    res = Kronk::Response.new mock_301_response
    assert res.redirect?

    res = Kronk::Response.new mock_302_response
    assert res.redirect?

    res = Kronk::Response.new mock_200_response
    assert !res.redirect?
  end


  def test_follow_redirect
    res1 = Kronk::Response.new mock_301_response
    assert res1.redirect?

    expect_request "GET", "http://www.google.com/"
    res2 = res1.follow_redirect

    assert_equal mock_200_response, res2.raw
  end


  def test_force_encoding
    return unless "".respond_to? :encoding

    res = Kronk::Response.new mock_200_response
    expected_encoding = Encoding.find "ISO-8859-1"

    assert_equal expected_encoding, res.encoding
    assert_equal expected_encoding, res.body.encoding
    assert_equal expected_encoding, res.raw.encoding

    res.force_encoding "utf-8"
    expected_encoding = Encoding.find "utf-8"

    assert_equal expected_encoding, res.encoding
    assert_equal expected_encoding, res.body.encoding
    assert_equal expected_encoding, res.raw.encoding
  end


  def test_stringify_string
    str = Kronk::Response.read_file("test/mocks/200_response.json").stringify
    expected = <<-STR
{
 "business": {
  "address": "3845 Rivertown Pkwy SW Ste 500",
  "city": "Grandville",
  "description": {
   "additional_urls": [
    {
     "destination": "http://example.com",
     "url_click": "http://example.com"
    }
   ],
   "general_info": "<p>A Paint Your Own Pottery Studios..</p>",
   "op_hours": "Fri 1pm-7pm, Sat 10am-6pm, Sun 1pm-4pm, Appointments Available",
   "payment_text": "DISCOVER, AMEX, VISA, MASTERCARD",
   "slogan": "<p>Pottery YOU dress up</p>"
  },
  "distance": 0.0,
  "has_detail_page": true,
  "headings": [
   "Pottery"
  ],
  "id": "1234",
  "impression_id": "mock_iid",
  "improvable": true,
  "latitude": 42.882561,
  "listing_id": "1234",
  "listing_type": "free",
  "longitude": -85.759586,
  "mappable": true,
  "name": "Naked Plates",
  "omit_address": false,
  "omit_phone": false,
  "phone": "6168055326",
  "rateable": true,
  "rating_count": 0,
  "red_listing": false,
  "state": "MI",
  "website": "http://example.com",
  "year_established": "1996",
  "zip": "49418"
 },
 "original_request": {
  "id": "1234"
 },
 "request_id": "mock_rid"
}
STR
    assert_equal expected.strip, str
  end


  def test_stringify_raw
    str = Kronk::Response.
      read_file("test/mocks/200_response.json").stringify :raw => 1

    expected = File.read("test/mocks/200_response.json").split("\r\n\r\n")[1]
    assert_equal expected, str
  end


  def test_stringify_struct
    str = Kronk::Response.read_file("test/mocks/200_response.json").
            stringify :struct => true

    expected = JSON.parse \
      File.read("test/mocks/200_response.json").split("\r\n\r\n")[1]

    expected = Kronk::DataString.new expected, :struct => true

    assert_equal expected, str
  end


  def test_stringify_missing_parser
    str = @html_resp.stringify
    expected = File.read("test/mocks/200_response.txt").split("\r\n\r\n")[1]

    assert_equal expected, str
  end


  def test_success?
    resp = Kronk::Response.read_file("test/mocks/200_response.txt")
    assert resp.success?

    resp = Kronk::Response.read_file("test/mocks/302_response.txt")
    assert !resp.success?
  end
end
