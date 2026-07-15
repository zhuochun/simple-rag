module TestAssertions
  private

  def assert_raises(error_class)
    yield
    raise "Expected #{error_class}, but nothing was raised"
  rescue error_class => error
    error
  end
end
