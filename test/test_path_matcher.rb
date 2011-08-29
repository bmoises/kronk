require 'test/test_helper'

class TestPathMatcher < Test::Unit::TestCase

  def setup
    @matcher = Kronk::Path::Matcher.new :key => "foo*", :value => "*bar*"
    @data = {
      :key1 => {
        :key1a => [
          "foo",
          "bar",
          "foobar",
          {:findme => "thing"}
        ],
        'key1b' => "findme"
      },
      'findme' => [
        123,
        456,
        {:findme => 123456}
      ],
      :key2 => "foobar",
      :key3 => {
        :key3a => ["val1", "val2", "val3"]
      }
    }
  end


  def test_new
    assert_equal %r{\Afoo(.*)\Z},     @matcher.key
    assert_equal %r{\A(.*)bar(.*)\Z}, @matcher.value
    assert !@matcher.recursive?
  end


  def test_find_in
    keys = []

    Kronk::Path::Matcher.new(:key => /key/).find_in @data do |data, key|
      keys << key.to_s
      assert_equal @data, data
    end

    assert_equal ['key1', 'key2', 'key3'], keys.sort
  end


  def test_find_in_recursive
    keys = []
    data_points = []

    matcher = Kronk::Path::Matcher.new :key       => :findme,
                                       :value     => "*",
                                       :recursive => true

    matcher.find_in @data do |data, key|
      keys << key.to_s
      data_points << data
    end

    assert_equal 3, keys.length
    assert_equal 1, keys.uniq.length
    assert_equal "findme", keys.first

    assert_equal 3, data_points.length
    assert data_points.include?(@data)
    assert data_points.include?({:findme => "thing"})
    assert data_points.include?({:findme => 123456})
  end


  def test_find_in_value
    keys = []
    data_points = []

    matcher = Kronk::Path::Matcher.new :key => "*", :value => "findme"
    matcher.find_in @data do |data, key|
      keys << key.to_s
      data_points << data
    end

    assert keys.empty?
    assert data_points.empty?

    matcher = Kronk::Path::Matcher.new :key       => "*",
                                       :value     => "findme",
                                       :recursive => true

    matcher.find_in @data do |data, key|
      keys << key.to_s
      data_points << data
    end

    assert_equal ['key1b'], keys
    assert_equal [@data[:key1]], data_points
  end
end
