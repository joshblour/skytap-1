class Hash
  def subset(keys)
    keys = keys.to_set
    reject do |k, v|
      !keys.include?(k)
    end
  end
end
