class BaseService
  attr_accessor :result, :error_status

  def valid?
    errors.blank?
  end

  def errors
    @errors ||= []
  end
end
